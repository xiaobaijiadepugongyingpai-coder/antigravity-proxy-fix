#!/usr/bin/env python3
"""
查询 Clash Verge / mihomo 的实际运行状态（支持 Windows 与 Ubuntu/Linux）。

用途：确认当前是全局模式还是规则模式、哪些节点在被使用。

用法：
    python query-mihomo.py           # 查配置
    python query-mihomo.py proxies   # 查所有策略组

原理：
- Windows: Clash Verge Rev 使用命名管道 (\\\\.\\pipe\\verge-mihomo*) 暴露 mihomo REST API。
- Linux:   Clash Verge Rev / mihomo 使用 Unix 域套接字 (/tmp/verge/verge-mihomo.sock 等)
           或 HTTP external-controller (如 127.0.0.1:9097 / 9090)。
"""

import glob
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request

# Windows 控制台默认 GBK，节点名里可能有 emoji，强制 UTF-8 输出
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass


# ---------------------------------------------------------------
# 读取配置（secret 与 external-controller）
# ---------------------------------------------------------------

def _config_candidates():
    home = os.path.expanduser("~")
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA", "")
        return [
            os.path.join(appdata, "io.github.clash-verge-rev.clash-verge-rev", "config.yaml"),
            os.path.join(appdata, "io.github.clash-verge-rev.clash-verge-rev", "clash-verge.yaml"),
            os.path.join(home, ".config", "clash", "config.yaml"),
        ]

    xdg_data = os.environ.get("XDG_DATA_HOME", os.path.join(home, ".local", "share"))
    xdg_conf = os.environ.get("XDG_CONFIG_HOME", os.path.join(home, ".config"))
    return [
        os.path.join(xdg_data, "io.github.clash-verge-rev.clash-verge-rev", "config.yaml"),
        os.path.join(xdg_conf, "io.github.clash-verge-rev.clash-verge-rev", "config.yaml"),
        os.path.join(xdg_conf, "clash-verge", "config.yaml"),
        os.path.join(xdg_conf, "mihomo", "config.yaml"),
        os.path.join(home, ".config", "clash", "config.yaml"),
    ]


def _read_yaml_scalar(key_name):
    prefix = f"{key_name}:"
    for path in _config_candidates():
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    stripped = line.strip()
                    if stripped.startswith(prefix):
                        val = stripped.split(":", 1)[1].strip()
                        # 去掉行尾注释
                        if " #" in val:
                            val = val.split(" #", 1)[0].strip()
                        val = val.strip('"').strip("'")
                        if val:
                            return val
        except OSError:
            pass
    return None


def find_secret():
    env_secret = os.environ.get("MIHOMO_SECRET")
    if env_secret is not None:
        return env_secret
    return _read_yaml_scalar("secret") or "set-your-secret"


def find_controller_urls():
    urls = []
    env_ctrl = os.environ.get("MIHOMO_CONTROLLER")
    if env_ctrl:
        urls.append(env_ctrl)
    cfg_ctrl = _read_yaml_scalar("external-controller")
    if cfg_ctrl:
        urls.append(cfg_ctrl)
    urls.extend(["127.0.0.1:9097", "127.0.0.1:9090"])

    out = []
    seen = set()
    for u in urls:
        u = u.strip().rstrip("/")
        if not u:
            continue
        if u.startswith(":"):
            u = "127.0.0.1" + u
        if not u.startswith("http://") and not u.startswith("https://"):
            u = "http://" + u
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


SECRET = find_secret()


# ---------------------------------------------------------------
# JSON 提取辅助（兼容 raw HTTP 响应 / chunked 编码）
# ---------------------------------------------------------------

def _extract_json(raw_text):
    i = raw_text.find("{")
    if i < 0:
        return None
    s = raw_text[i:]
    # 先尝试标准 JSON 解码（处理字符串中含花括号的场景更可靠）
    try:
        obj, _ = json.JSONDecoder().raw_decode(s)
        return obj
    except json.JSONDecodeError:
        pass

    # 若存在 chunked 帧标记穿插，去掉 HTTP header 后按块重组再解码
    sep = raw_text.find("\r\n\r\n")
    if sep >= 0:
        body = raw_text[sep + 4 :]
        parts = []
        pos = 0
        while pos < len(body):
            crlf = body.find("\r\n", pos)
            if crlf < 0:
                break
            size_hex = body[pos:crlf].split(";", 1)[0].strip()
            try:
                size = int(size_hex, 16)
            except ValueError:
                break
            if size == 0:
                break
            start = crlf + 2
            parts.append(body[start : start + size])
            pos = start + size + 2
        if parts:
            try:
                return json.loads("".join(parts))
            except json.JSONDecodeError:
                pass
    return None


# ---------------------------------------------------------------
# 传输层 1：Windows 命名管道
# ---------------------------------------------------------------

if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _k32.CreateFileW.restype = wintypes.HANDLE
    _k32.CreateFileW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
        wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    ]
    _k32.ReadFile.argtypes = [
        wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID,
    ]
    _k32.WriteFile.argtypes = [
        wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID,
    ]
    _k32.CloseHandle.argtypes = [wintypes.HANDLE]


def find_pipe():
    """在 \\\\.\\pipe\\ 下找 verge-mihomo-* 管道（仅 Windows）"""
    if sys.platform != "win32":
        return None
    candidates = []
    try:
        for name in os.listdir("\\\\.\\pipe\\"):
            if "mihomo" in name.lower():
                candidates.append("\\\\.\\pipe\\" + name)
    except OSError:
        pass
    for c in candidates:
        if "sidecar" in c.lower():
            return c
    return candidates[0] if candidates else None


def _request_windows_pipe(pipe_path, path, retries=8, delay=0.25):
    """通过 Windows 命名管道发 GET 请求（带退避重试）。"""
    GENERIC_READ, GENERIC_WRITE, OPEN_EXISTING = 0x80000000, 0x40000000, 3
    INVALID = ctypes.c_void_p(-1).value

    h = None
    for attempt in range(retries):
        h = _k32.CreateFileW(
            pipe_path, GENERIC_READ | GENERIC_WRITE, 0, None, OPEN_EXISTING, 0, None
        )
        if h and h != INVALID:
            break
        h = None
        time.sleep(delay * (attempt + 1))
    if h is None:
        return None

    req = (
        f"GET {path} HTTP/1.1\r\nHost: localhost\r\n"
        f"Authorization: Bearer {SECRET}\r\nConnection: close\r\n\r\n"
    )
    written = wintypes.DWORD(0)
    buf = ctypes.create_string_buffer(req.encode("utf-8"))
    _k32.WriteFile(h, buf, len(req), ctypes.byref(written), None)

    chunks, total = [], 0
    rb = ctypes.create_string_buffer(65536)
    read = wintypes.DWORD(0)
    while total < 8_000_000:
        ok = _k32.ReadFile(h, rb, 65536, ctypes.byref(read), None)
        if not ok or read.value == 0:
            break
        chunks.append(rb.raw[: read.value])
        total += read.value
    _k32.CloseHandle(h)

    raw = b"".join(chunks).decode("utf-8", "replace")
    return _extract_json(raw)


# ---------------------------------------------------------------
# 传输层 2：Linux / macOS Unix Domain Socket
# ---------------------------------------------------------------

def find_unix_socket():
    if sys.platform == "win32" or not hasattr(socket, "AF_UNIX"):
        return None

    env_sock = os.environ.get("MIHOMO_SOCKET")
    if env_sock and os.path.exists(env_sock):
        return env_sock

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "")
    home = os.path.expanduser("~")
    xdg_data = os.environ.get("XDG_DATA_HOME", os.path.join(home, ".local", "share"))

    patterns = [
        "/tmp/verge/verge-mihomo*.sock",
        "/tmp/verge-mihomo*.sock",
        "/tmp/*mihomo*.sock",
        os.path.join(xdg_data, "io.github.clash-verge-rev.clash-verge-rev", "*.sock"),
    ]
    if runtime_dir:
        patterns.insert(0, os.path.join(runtime_dir, "verge", "verge-mihomo*.sock"))
        patterns.insert(1, os.path.join(runtime_dir, "verge-mihomo*.sock"))

    candidates = []
    for pat in patterns:
        for match in glob.glob(pat):
            if match not in candidates:
                candidates.append(match)

    for c in candidates:
        if "sidecar" in c.lower():
            return c
    return candidates[0] if candidates else None


def _request_unix_socket(sock_path, path, retries=4, delay=0.2):
    req = (
        f"GET {path} HTTP/1.1\r\nHost: localhost\r\n"
        f"Authorization: Bearer {SECRET}\r\nConnection: close\r\n\r\n"
    ).encode("utf-8")

    for attempt in range(retries):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(3.0)
        try:
            s.connect(sock_path)
            s.sendall(req)
            chunks, total = [], 0
            while total < 8_000_000:
                data = s.recv(65536)
                if not data:
                    break
                chunks.append(data)
                total += len(data)
            raw = b"".join(chunks).decode("utf-8", "replace")
            return _extract_json(raw)
        except OSError:
            time.sleep(delay * (attempt + 1))
        finally:
            try:
                s.close()
            except OSError:
                pass
    return None


# ---------------------------------------------------------------
# 传输层 3：HTTP external-controller 回退（全平台通用，绕过代理直连本机）
# ---------------------------------------------------------------

def _request_http_controller(path):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    headers = {"Authorization": f"Bearer {SECRET}"} if SECRET else {}
    for base in find_controller_urls():
        url = base + path
        req = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with opener.open(req, timeout=2.0) as resp:
                raw = resp.read(8_000_000).decode("utf-8", "replace")
                data = _extract_json(raw)
                if data is not None:
                    return data, base
        except (urllib.error.URLError, OSError, TimeoutError):
            continue
    return None, None


def request(path):
    """自动选择本机可用的 mihomo 控制通道并发送 GET 请求。"""
    if sys.platform == "win32":
        pipe = find_pipe()
        if pipe:
            data = _request_windows_pipe(pipe, path)
            if data is not None:
                return data
    else:
        sock_path = find_unix_socket()
        if sock_path:
            data = _request_unix_socket(sock_path, path)
            if data is not None:
                return data

    data, _ = _request_http_controller(path)
    return data


def main():
    # 支持 --path 形式，避免 Git Bash / MSYS2 把 /proxies 转换成 Windows 路径
    args = sys.argv[1:]

    if not args or args[0] in ("configs", "config", "--configs"):
        which = "/configs"
    elif args[0] in ("proxies", "proxy", "--proxies"):
        which = "/proxies"
    elif args[0].startswith("/"):
        which = args[0]
    else:
        which = "/" + args[0]

    data = request(which)
    if data is None:
        if sys.platform == "win32":
            print("未找到或无法读取 mihomo 控制通道（命名管道 / HTTP controller），请确认 Clash 正在运行")
            print("提示：mihomo 的 sidecar 管道有连接数限制，稍等一两秒再试")
        else:
            print("未找到或无法读取 mihomo 控制通道（Unix socket / HTTP external-controller），请确认 Clash 正在运行")
            print("提示：也可通过 MIHOMO_SOCKET 或 MIHOMO_CONTROLLER=http://127.0.0.1:9097 指定地址")
        return

    if which.startswith("/configs"):
        print(f"{'mode':12} = {data.get('mode')}")
        print(f"{'mixed-port':12} = {data.get('mixed-port')}")
        print(f"{'socks-port':12} = {data.get('socks-port')}")
        tun = data.get("tun") or {}
        print(f"{'tun.enable':12} = {tun.get('enable')}")

    elif which.startswith("/proxies"):
        proxies = data.get("proxies", {})
        groups = []
        for name, v in proxies.items():
            if v.get("type") in ("Selector", "URLTest", "Fallback", "LoadBalance", "Relay"):
                groups.append((name, v["type"], v.get("now"), len(v.get("all", []))))

        print(f"共 {len(groups)} 个策略组：\n")
        for name, typ, now, n in sorted(groups, key=lambda x: x[1]):
            note = ""
            if typ == "URLTest":
                note = "  ← 自动测速，IP 会跳"
            elif typ == "Selector":
                note = "  ← 手动固定"
            print(f"  [{typ:9}] {name:24} -> {now}   (备选 {n}){note}")

    else:
        print(json.dumps(data, ensure_ascii=False, indent=2)[:2000])


if __name__ == "__main__":
    main()
