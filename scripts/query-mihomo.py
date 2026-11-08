#!/usr/bin/env python3
"""
查询 Clash Verge / mihomo 的实际运行状态。

用途：确认当前是全局模式还是规则模式、哪些节点在被使用、出口 IP 归属。

用法：
    python query-mihomo.py           # 查配置
    python query-mihomo.py /proxies  # 查所有策略组

原理：Clash Verge Rev 使用命名管道暴露 mihomo 的 REST API（而非 HTTP 端口），
管道名包含本机实例的哈希，所以需要自动发现。
"""

import ctypes
import glob
import json
import os
import sys
from ctypes import wintypes

# Windows 控制台默认 GBK，节点名里可能有 emoji，强制 UTF-8 输出
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

# ---------------------------------------------------------------
# 自动发现 mihomo 的命名管道
# ---------------------------------------------------------------

def find_pipe():
    """在 \\.\pipe\ 下找 verge-mihomo-* 管道"""
    candidates = []
    try:
        for name in os.listdir("\\\\.\\pipe\\"):
            if "mihomo" in name.lower():
                candidates.append("\\\\.\\pipe\\" + name)
    except OSError:
        pass
    # 优先 sidecar 管道（Clash Verge Rev 用这个）
    for c in candidates:
        if "sidecar" in c.lower():
            return c
    return candidates[0] if candidates else None


PIPE = find_pipe() or r"\\.\pipe\verge-mihomo"

# ---------------------------------------------------------------
# 读取 secret
# ---------------------------------------------------------------

def find_secret():
    """从 Clash Verge 配置文件里读 external-controller 的 secret"""
    candidates = [
        os.path.join(os.environ.get("APPDATA", ""),
                     "io.github.clash-verge-rev.clash-verge-rev", "config.yaml"),
        os.path.join(os.environ.get("USERPROFILE", ""), ".config", "clash", "config.yaml"),
    ]
    for path in candidates:
        if not os.path.exists(path):
            continue
        try:
            for line in open(path, encoding="utf-8", errors="ignore"):
                if line.strip().startswith("secret:"):
                    return line.split(":", 1)[1].strip().strip('"').strip("'")
        except OSError:
            pass
    return "set-your-secret"


SECRET = find_secret()

# ---------------------------------------------------------------
# 通过命名管道发 HTTP 请求
# ---------------------------------------------------------------

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_k32.CreateFileW.restype = wintypes.HANDLE
_k32.CreateFileW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
    wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
]
_k32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                          ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
_k32.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
                           ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
_k32.CloseHandle.argtypes = [wintypes.HANDLE]


def request(path, retries=8, delay=0.25):
    """通过命名管道发一个 GET 请求。

    注意：mihomo 的 sidecar 管道对同一时刻的连接数有限制，上一次连接
    未完全释放时 CreateFileW 会失败。所以这里需要退避重试。
    """
    import time

    GENERIC_READ, GENERIC_WRITE, OPEN_EXISTING = 0x80000000, 0x40000000, 3
    INVALID = ctypes.c_void_p(-1).value

    h = None
    for attempt in range(retries):
        h = _k32.CreateFileW(PIPE, GENERIC_READ | GENERIC_WRITE, 0, None,
                             OPEN_EXISTING, 0, None)
        if h and h != INVALID:
            break
        h = None
        time.sleep(delay * (attempt + 1))   # 递增退避
    if h is None:
        return None

    req = (
        f"GET {path} HTTP/1.1\r\nHost: localhost\r\n"
        f"Authorization: Bearer {SECRET}\r\nConnection: close\r\n\r\n"
    )
    written = wintypes.DWORD(0)
    buf = ctypes.create_string_buffer(req.encode())
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
    i = raw.find("{")
    if i < 0:
        return None
    s = raw[i:]
    depth = 0
    for j, ch in enumerate(s):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(s[: j + 1])
                except json.JSONDecodeError:
                    return None
    return None


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

    if not PIPE:
        print("未找到 mihomo 命名管道，请确认 Clash 正在运行")
        return

    data = request(which)
    if data is None:
        print(f"无法从管道读取数据: {PIPE}")
        print("提示：mihomo 的 sidecar 管道有连接数限制，稍等一两秒再试")
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
