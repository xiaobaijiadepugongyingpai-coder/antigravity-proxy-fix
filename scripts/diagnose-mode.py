#!/usr/bin/env python3
"""
跨平台一键诊断脚本（Windows + Ubuntu/Linux）：
排查 Clash 模式、策略组节点指向，以及 Antigravity/Google 上游逐域名连通性与 TLS 延迟。

用法：
    python3 scripts/diagnose-mode.py
    python3 scripts/diagnose-mode.py --proxy http://127.0.0.1:7890
"""

import argparse
import importlib.util
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

DOMAINS = [
    "cloudcode-pa.googleapis.com",
    "daily-cloudcode-pa.googleapis.com",
    "oauth2.googleapis.com",
    "accounts.google.com",
    "www.google.com",
]

SUSPICIOUS_NODE_RE = re.compile(
    r"^(DIRECT|REJECT)$|剩余|到期|重置|流量|官网|\b(GB|TB|MB|Traffic|Expire|Reset)\b",
    re.IGNORECASE,
)


def normalize_proxy(raw):
    if not raw:
        return None
    s = raw.strip().strip('"').strip("'").strip()
    if not s:
        return None
    if s.isdigit():
        p = int(s)
        return f"http://127.0.0.1:{p}" if 1 <= p <= 65535 else None
    if "://" not in s:
        s = "http://" + s
    u = urllib.parse.urlparse(s)
    if u.hostname and u.port and 1 <= u.port <= 65535:
        return s
    return None


def read_proxy_conf():
    home = os.path.expanduser("~")
    if sys.platform == "win32":
        paths = [os.path.join(home, ".agy-shim", "proxy.conf")]
    else:
        xdg_conf = os.environ.get("XDG_CONFIG_HOME", os.path.join(home, ".config"))
        paths = [os.path.join(xdg_conf, "agy-proxy", "proxy.conf")]
    for path in paths:
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    t = line.strip()
                    if not t or t.startswith("#") or t.startswith(";"):
                        continue
                    if "=" in t:
                        k, v = t.split("=", 1)
                        if k.strip().upper() in (
                            "ANTIGRAVITY_PROXY", "AGY_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "PROXY"
                        ):
                            t = v
                    n = normalize_proxy(t)
                    if n:
                        return n
        except OSError:
            pass
    return None


def probe_tcp(proxy_url, timeout=0.5):
    u = urllib.parse.urlparse(proxy_url)
    t0 = time.perf_counter()
    try:
        with socket.create_connection((u.hostname, u.port), timeout=timeout):
            return True, int((time.perf_counter() - t0) * 1000)
    except OSError:
        return False, -1


def load_query_mihomo():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "query-mihomo.py")
    if not os.path.isfile(path):
        return None
    spec = importlib.util.spec_from_file_location("query_mihomo", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def probe_domain_curl(curl_bin, proxy_url, domain, timeout_sec):
    cmd = [
        curl_bin,
        "-x", proxy_url,
        "-s",
        "-o", os.devnull,
        "-w", "%{http_code}|%{time_appconnect}|%{time_total}",
        "--max-time", str(timeout_sec),
        f"https://{domain}/",
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec + 5)
        parts = r.stdout.strip().split("|")
        code = parts[0] if len(parts) >= 1 and parts[0] else "000"
        tls = float(parts[1]) if len(parts) >= 2 and parts[1] else 0.0
        total = float(parts[2]) if len(parts) >= 3 and parts[2] else 0.0
        return code, tls, total
    except (OSError, subprocess.SubprocessError, ValueError):
        return "000", 0.0, 0.0


def main():
    parser = argparse.ArgumentParser(description="Diagnose Clash mode/node and Google AI upstream reachability.")
    parser.add_argument("--proxy", default="", help="Explicit proxy URL or port (e.g. http://127.0.0.1:7890)")
    parser.add_argument("--timeout", type=int, default=10, help="Per-domain timeout in seconds (default: 10)")
    args = parser.parse_args()

    print("=== 1. Proxy discovery ===")
    raw_cands = [
        normalize_proxy(args.proxy),
        normalize_proxy(os.environ.get("ANTIGRAVITY_PROXY")),
        normalize_proxy(os.environ.get("AGY_PROXY")),
        read_proxy_conf(),
        "http://127.0.0.1:7897",
        "http://127.0.0.1:7890",
        "http://127.0.0.1:10809",
    ]
    seen = set()
    chosen = None
    for c in raw_cands:
        if not c or c in seen:
            continue
        seen.add(c)
        ok, ms = probe_tcp(c)
        if ok:
            chosen = c
            print(f"  REACHABLE : {c} ({ms} ms)")
            break
        print(f"  closed    : {c}")

    if not chosen:
        print("\n[VERDICT] No local proxy port is reachable. Check whether Clash / proxy client is running.")
        return 2

    print("\n=== 2. Clash / mihomo mode & active groups ===")
    qm = load_query_mihomo()
    if qm is not None:
        cfg = qm.request("/configs")
        if cfg:
            tun = cfg.get("tun") or {}
            print(f"  mode       = {cfg.get('mode')}")
            print(f"  mixed-port = {cfg.get('mixed-port')}")
            print(f"  socks-port = {cfg.get('socks-port')}")
            print(f"  tun.enable = {tun.get('enable')}")
        else:
            print("  (could not query /configs from mihomo)")

        px = qm.request("/proxies")
        if px and isinstance(px.get("proxies"), dict):
            warnings = []
            groups = []
            for name, v in px["proxies"].items():
                if v.get("type") in ("Selector", "URLTest", "Fallback", "LoadBalance", "Relay"):
                    groups.append((name, v["type"], v.get("now") or "", len(v.get("all", []))))
            print(f"  groups ({len(groups)}):")
            for name, typ, now, n in sorted(groups, key=lambda x: (x[1], x[0])):
                note = "  [URLTest: IP may hop]" if typ == "URLTest" else ""
                print(f"    [{typ:9}] {name:24} -> {now} (count={n}){note}")
                if typ == "Selector" and SUSPICIOUS_NODE_RE.search(now):
                    warnings.append(f"{name} -> {now}")
            if warnings:
                print("\n  [WARN] Suspicious Selector target(s) detected:")
                for w in warnings:
                    print(f"    ! {w}")
    else:
        print("  (scripts/query-mihomo.py not found)")

    print(f"\n=== 3. Per-domain reachability via {chosen} ===")
    curl_bin = shutil.which("curl.exe" if sys.platform == "win32" else "curl")
    if not curl_bin:
        print("  [ERROR] curl not found in PATH.")
        return 1

    print(f"  {'Domain':36} {'Code':6} {'TLS(s)':10} {'Total(s)'}")
    results = []
    for d in DOMAINS:
        code, tls, total = probe_domain_curl(curl_bin, chosen, d, args.timeout)
        print(f"  {d:36} {code:6} {tls:<10.3f} {total:.3f}")
        results.append((d, code, tls, total))

    print("\n=== 4. Verdict ===")
    all_failed = all(c == "000" for _, c, _, _ in results)
    ai_failed = any("cloudcode-pa" in d and c == "000" for d, c, _, _ in results)
    core_ok = any("cloudcode-pa" not in d and c != "000" for d, c, _, _ in results)
    slow_ai = any(d == "cloudcode-pa.googleapis.com" and c != "000" and tls > 1.0 for d, c, tls, _ in results)

    if all_failed:
        print("[FAIL] All Google domains returned 000 via proxy.")
        print("       Likely cause: active Clash node is down, GLOBAL is on DIRECT/REJECT or a fake info node, or wrong port.")
        return 2
    if ai_failed and core_ok:
        print("[NODE ISSUE] General Google works, but cloudcode-pa failed (000).")
        print("             Proxy injection is fine; switch to another node for Google AI upstream.")
        return 3
    if slow_ai:
        print("[SLOW] All domains reachable, but cloudcode-pa TLS handshake > 1.0s.")
        print("       Consider switching GLOBAL / proxy group to a lower-latency node.")
        return 0
    print("[OK] Proxy port, active node, and all Antigravity/Google endpoints look healthy.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
