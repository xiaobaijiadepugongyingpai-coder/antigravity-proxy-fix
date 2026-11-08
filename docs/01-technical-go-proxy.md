# 本地页面超时，根因却在远端：一次 Antigravity / agy 卡死问题的排查

> **环境**：Windows 11 (10.0.26200) · Antigravity 2.29.1 · Antigravity CLI (agy) 1.5.3
> **症状**：桌面版一直停在加载页面；CLI 登录时报网络超时
> **真正的原因**：Go 程序只读环境变量，不读 Windows 系统代理设置

---

## 一、现象：一个极具误导性的报错

### 1.1 命令行工具

```
Got an error: token exchange failed: Post "https://oauth2.googleapis.com/token":
dial tcp 173.194.203.95:443: connectex: A connection attempt failed because
the connected party did not properly respond after a period of time, or
established connection failed because connected host has failed to respond.
```

这个还算直观——连接对端没响应，典型的网络不通。

### 1.2 桌面客户端

浏览器能正常访问 Google，但这个 Electron 应用一直转圈。日志里是：

```
[error] (node:39312) electron: Failed to load URL: https://127.0.0.1:12111/
        with error: ERR_TIMED_OUT
```

**注意这个 `127.0.0.1`。** 本地地址，本地服务，超时了。

绝大多数人在这一步的判断是：**本地服务挂了 → 重装软件**。

然后重装完，还是一样。

---

## 二、转折点：另一份日志

真正的答案不在 Electron 的日志里，而在它的**内核进程**日志中。

同一时刻的 `language_server.log`：

```
W auth_client.go:415] Failed to get granted scopes in validation:
failed to call tokeninfo: Get "https://www.googleapis.com/oauth2/v3/tokeninfo?access_token=ya29...":
dial tcp 172.217.115.4:443: i/o timeout
```

`dial tcp ... i/o timeout` —— 这是 **Go 运行时 `net.Dial` 的经典错误格式**。

它证明了一件关键的事：**这个应用内部有一个 Go 写的进程，正在直连外网，并且失败了。**

### 2.1 为什么"本地页面超时"是假象

Antigravity 是**双进程架构**：

```
Antigravity.exe          ← Electron 外壳（负责窗口、UI 渲染）
    └─ language_server.exe   ← Go 内核（负责登录、API 请求、状态管理）
```

完整链路：

```
1. Electron 外壳启动，监听 127.0.0.1:PORT
2. 外壳拉起 Go 内核
3. Go 内核校验登录态 → 请求远端接口 → 30 秒超时
4. 内核没有就绪状态，无法提供 UI 需要的完整响应
5. Electron 加载 https://127.0.0.1:PORT/ → 拿不到完整数据 → ERR_TIMED_OUT
6. 用户看到白屏
```

**所以：本地页面超时是症状，远端连不上才是原因。**

这个坑的隐蔽之处在于——**报错信息完全指向错误的方向**。如果不去看内核日志，排查会一直在错误的分支上打转。

---

## 三、根因：Go 不读 Windows 系统代理

### 3.1 关键事实

| 运行时 | Windows 系统代理（IE 设置） | `HTTP_PROXY` / `HTTPS_PROXY` 环境变量 |
|---|---|---|
| 浏览器（Chrome / Edge） | ✅ 认 | ✅ 认 |
| Electron（Chromium 网络栈） | ✅ 认 | ✅ 认 |
| **Go 程序** | ❌ **完全不认** | ✅ 认 |
| **Rust 程序** | ❌ **完全不认** | ✅ 认 |

Go 的 `net/http` 通过 `http.ProxyFromEnvironment` 获取代理配置，它的**唯一来源是环境变量**。它不会去读：

- 注册表里的 `Internet Settings`
- `netsh winhttp` 的设置
- PAC 文件
- 任何操作系统的图形化代理设置

### 3.2 本机实测

```
# 走环境变量指定代理
curl -x http://127.0.0.1:7897 https://www.google.com/generate_204  → 204

# 完全直连（绕过所有代理）
curl --noproxy '*' https://oauth2.googleapis.com/token             → 超时 exit 28
```

**同一台机器、同一时刻：走代理能通，直连不通。**

而 `agy` 和 `language_server.exe` 恰恰在直连——因为它们读不到系统代理设置。

### 3.3 结论

> 当系统代理只配置在「系统设置」里、没有配置成环境变量时，**所有 Go / Rust 编写的程序实际上都在直连**。

这就是"浏览器能上，命令行工具不行"的根本原因。

---

## 四、为什么不直接设置全局环境变量

最直觉的做法：

```powershell
setx HTTPS_PROXY "http://127.0.0.1:7897"
setx HTTP_PROXY  "http://127.0.0.1:7897"
```

**不推荐，副作用很大：**

1. **本机服务会被代理**：任何访问 `127.0.0.1` 的请求都会送进代理 → 502
2. **内网设备失灵**：NAS、开发服务器、局域网接口全部走代理
3. **单点故障**：代理软件一关，**整个系统的网络访问全部中断**，包括你的开发工具
4. **难以排查**：以后遇到任何网络问题，都会先怀疑是不是代理变量在捣乱

### 实测对照

本地起一个服务（`127.0.0.1:18080`）：

```
direct    → 200
via proxy → 502   ← 本地回环被塞进代理的后果
```

所以正确做法是：**只给需要的程序注入，不动全局。**

---

## 五、方案：进程级环境变量注入

### 5.1 目标

```
┌────────────────────────────────────────────┐
│  Windows 环境（干净，无任何代理变量）        │
│                                             │
│  其它程序 ──直连──> 不受影响                 │
│                                             │
│  目标程序 ──注入变量──> 127.0.0.1:7897       │
└────────────────────────────────────────────┘
```

### 5.2 为什么 CLII 用原生 exe，而 GUI 用 .cmd

这两个程序的技术约束不同，所以实现方式也不同：

| 程序 | 方式 | 原因 |
|---|---|---|
| CLI 工具 | **C 编译的原生转发器** | 交互式 TUI；可能被 `subprocess` 调用；需要精确透传退出码和 stdio。`.cmd` 中间层在这些场景不可靠 |
| GUI 应用 | **`.cmd` 启动器** | 双击启动，无 stdio / 退出码顾虑；`.cmd` 便于用户自行修改，无需编译环境 |

### 5.3 转发器源码

保存为 `shim.c`：

```c
/*
 * shim: 只给目标程序注入代理环境变量，其它程序完全不受影响。
 *
 * 行为：
 *   1. 如果进程环境里已经存在 HTTP_PROXY / HTTPS_PROXY，原样放行。
 *   2. 否则探测本机代理端口，通的话注入给子进程。
 *   3. 一个都探不通就不注入，让程序保持原生行为。
 *   4. 用真实路径启动目标程序，参数原样透传，退出码原样返回。
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int probe_port(unsigned short port)
{
    SOCKET s;
    struct sockaddr_in a;
    int ok;

    s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET)
        return 0;

    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");

    ok = (connect(s, (struct sockaddr *)&a, sizeof a) == 0);
    closesocket(s);
    return ok;
}

static unsigned short port_of(const wchar_t *url)
{
    const wchar_t *colon = wcsrchr(url, L':');
    if (!colon)
        return 0;
    return (unsigned short)wcstoul(colon + 1, NULL, 10);
}

static void maybe_set_proxy(void)
{
    const wchar_t *cands[4];
    wchar_t custom[512];
    int n = 0, i;
    const wchar_t *chosen = NULL;
    DWORD cl;

    /* 用户已经自己配了，不插手。
     * 注意：Go 的 ProxyFromEnvironment 在 HTTPS_PROXY 未设置时会回退到
     * HTTP_PROXY，所以只设 HTTP_PROXY 也是有效配置，同样必须尊重。 */
    if (GetEnvironmentVariableW(L"HTTPS_PROXY", NULL, 0) != 0 ||
        GetEnvironmentVariableW(L"https_proxy", NULL, 0) != 0 ||
        GetEnvironmentVariableW(L"HTTP_PROXY", NULL, 0) != 0 ||
        GetEnvironmentVariableW(L"http_proxy", NULL, 0) != 0)
        return;

    cl = GetEnvironmentVariableW(L"TARGET_PROXY", custom, 512);
    if (cl > 0 && cl < 512)
        cands[n++] = custom;

    cands[n++] = L"http://127.0.0.1:7897";
    cands[n++] = L"http://127.0.0.1:7890";

    for (i = 0; i < n; i++) {
        unsigned short p = port_of(cands[i]);
        if (p && probe_port(p)) {
            chosen = cands[i];
            break;
        }
    }

    if (!chosen)
        return;

    SetEnvironmentVariableW(L"HTTPS_PROXY", chosen);
    SetEnvironmentVariableW(L"HTTP_PROXY", chosen);

    /* 本地回环绝不能走代理 */
    if (GetEnvironmentVariableW(L"NO_PROXY", NULL, 0) == 0 &&
        GetEnvironmentVariableW(L"no_proxy", NULL, 0) == 0)
        SetEnvironmentVariableW(L"NO_PROXY", L"localhost,127.0.0.1,::1");
}

int main(void)
{
    wchar_t self[MAX_PATH];
    wchar_t base[MAX_PATH];
    wchar_t real[MAX_PATH];
    wchar_t *slash;
    const wchar_t *cmdline, *rest;
    wchar_t *full;
    size_t need;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    WSADATA wsa;

    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) {
        fwprintf(stderr, L"shim: GetModuleFileNameW failed\n");
        return 1;
    }

    wcsncpy(base, self, MAX_PATH - 1);
    base[MAX_PATH - 1] = 0;
    slash = wcsrchr(base, L'\\');
    if (slash)
        *slash = 0; /* ...\target\shim */

    /* 真实程序位置，按顺序尝试 */
    real[0] = 0;
    {
        wchar_t probe[MAX_PATH];
        DWORD cl = GetEnvironmentVariableW(L"REAL_EXE", probe, MAX_PATH);
        if (cl > 0 && cl < MAX_PATH &&
            GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
            wcsncpy(real, probe, MAX_PATH - 1);

        if (!real[0]) {
            _snwprintf(probe, MAX_PATH, L"%s\\bin\\app.exe", base);
            probe[MAX_PATH - 1] = 0;
            if (GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
                wcsncpy(real, probe, MAX_PATH - 1);
        }
    }
    real[MAX_PATH - 1] = 0;

    if (!real[0]) {
        fwprintf(stderr, L"shim: cannot locate real exe near %s\n", base);
        return 1;
    }

    if (WSAStartup(MAKEWORD(2, 2), &wsa) == 0) {
        maybe_set_proxy();
        WSACleanup();
    }

    cmdline = GetCommandLineW();
    rest = cmdline;
    if (*rest == L'"') {
        rest++;
        while (*rest && *rest != L'"')
            rest++;
        if (*rest == L'"')
            rest++;
    } else {
        while (*rest && *rest != L' ' && *rest != L'\t')
            rest++;
    }

    need = wcslen(real) + wcslen(rest) + 8;
    full = (wchar_t *)malloc(need * sizeof(wchar_t));
    if (!full)
        return 1;
    _snwprintf(full, need, L"\"%s\"%s", real, rest);

    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    memset(&pi, 0, sizeof pi);

    if (!CreateProcessW(NULL, full, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        fwprintf(stderr, L"shim: CreateProcessW failed (%lu)\n", GetLastError());
        free(full);
        return 1;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    free(full);
    return (int)code;
}
```

**三个关键设计点**：

1. **尊重已有配置**：环境里已有 `HTTPS_PROXY` 就直接放行，不覆盖用户的设置
2. **探测失败不注入**：代理没开时保持程序原生行为，避免"修得更坏"
3. **退出码精确透传**：`WaitForSingleObject` + `GetExitCodeProcess`，保证父进程拿到的返回值与原生一致

### 5.4 编译

需要 MinGW-w64（VS Code 的 mingw 包、MSYS2、Chocolatey 均可）：

```powershell
gcc -O2 -s -Wall -o "shim.exe" shim.c -lws2_32
```

产物约 18 KB。

### 5.5 放到 PATH 最前面

```powershell
$shimDir = '%LOCALAPPDATA%\agy\shim'
$key = Get-Item 'HKCU:\Environment'

# 必须用 DoNotExpandEnvironmentNames，否则 %VAR% 会被展开成硬编码路径
$raw = $key.GetValue('Path', '',
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

$parts = $raw -split ';' | Where-Object { $_.Trim() -ne '' }
$new = (@($shimDir) + $parts) -join ';'

[Microsoft.Win32.Registry]::SetValue(
    'HKEY_CURRENT_USER\Environment', 'Path', $new,
    [Microsoft.Win32.RegistryValueKind]::ExpandString)   # 保持 ExpandString 类型
```

目录结构：

```
%LOCALAPPDATA%\agy\
  ├─ shim\shim.exe    ← 转发器（PATH 最前）
  └─ bin\app.exe      ← 原始程序（未改动）
```

**改完要重开终端**（PATH 是进程启动时读取的）。

### 5.6 GUI 应用：启动器脚本

```bat
@echo off
REM 只给本程序注入代理，不影响其它软件

setlocal

if not defined APP_PROXY set "APP_PROXY=http://127.0.0.1:7897"

REM 本地回环必须绕开，否则应用自己的本地页面会挂
set "NO_PROXY=localhost,127.0.0.1,::1"
set "no_proxy=localhost,127.0.0.1,::1"

set "HTTPS_PROXY=%APP_PROXY%"
set "HTTP_PROXY=%APP_PROXY%"
set "https_proxy=%APP_PROXY%"
set "http_proxy=%APP_PROXY%"

set "APP=%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe"

if not exist "%APP%" (
    echo [ERROR] Antigravity.exe not found
    echo   expected: %APP%
    pause
    exit /b 1
)

REM 探测端口，不通只警告不阻止启动
powershell -NoProfile -Command ^
  "$h=$env:HTTPS_PROXY -replace '^https?://',''; $p=[int]($h -split ':')[-1]; $ok=$false; try{ $c=New-Object Net.Sockets.TcpClient; $r=$c.BeginConnect('127.0.0.1',$p,$null,$null); $ok=$r.AsyncWaitHandle.WaitOne(800); if($ok){$c.EndConnect($r)}; $c.Close() }catch{}; if(-not $ok){ Write-Host ('[WARN] proxy port ' + $p + ' not responding.') -ForegroundColor Yellow; Start-Sleep -Seconds 2 }"

start "" "%APP%"

endlocal
```

### 5.7 改快捷方式

```powershell
$launcher = 'C:\path\to\launcher.cmd'
$exe      = "$env:LOCALAPPDATA\Programs\antigravity\Antigravity.exe"

$targets = @(
    (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk')
)

$sh = New-Object -ComObject WScript.Shell
foreach ($t in $targets) {
    if (-not (Test-Path $t)) { continue }
    $s = $sh.CreateShortcut($t)
    $s.TargetPath       = $launcher
    $s.Arguments        = ''
    $s.WorkingDirectory = Split-Path $launcher
    $s.IconLocation     = $exe + ',0'    # 保留原图标
    $s.WindowStyle      = 7              # 最小化，避免 cmd 黑框闪
    $s.Save()
}

# 改完必须逐一验证 —— 批量修改最容易漏掉其中一个
$bad = 0
foreach ($t in $targets) {
    if (-not (Test-Path $t)) { continue }
    $target = $sh.CreateShortcut($t).TargetPath
    if ($target -like '*.cmd') {
        Write-Host "  OK   $t"
    } else {
        Write-Host "  FAIL $t -> $target" -ForegroundColor Red
        $bad++
    }
}
if ($bad) { Write-Warning "$bad 个快捷方式未生效" }
```

> **为什么必须验证**：批量修改多处时，很容易只确认手边那一个。实测遇到过「桌面改好了、开始菜单被更新器还原」的情况——从桌面启动正常，从开始菜单启动原故障完整复发，排查难度极高。

---

## 六、验证

### 6.1 功能

```bash
$ agy models
gemini-3.8-flash-high    Gemini 3.8 Flash (High)
claude-sonnet-4-6        Claude Sonnet 4.6 (Thinking)
...

$ agy -p "reply with exactly: OK"
OK
```

### 6.2 修复前后

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `dial tcp ... i/o timeout` | 存在 | **0 次** |
| `ERR_TIMED_OUT` | 存在 | **0 次** |
| 本地页面 HTTPS | 超时 | **HTTP 200 / 24ms** |

### 6.3 隔离性

```powershell
foreach($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY'){
    $u = [Environment]::GetEnvironmentVariable($n,'User')
    $m = [Environment]::GetEnvironmentVariable($n,'Machine')
    "$n  user=$(if($u){$u}else{'<未设置>'})  machine=$(if($m){$m}else{'<未设置>'})"
}
```

输出全部为「未设置」——**全局环境干净，只有目标程序拿到了变量**。

### 6.4 退出码透传

```bash
$ agy --definitely-not-a-flag
$ echo $?
2        # 与原生程序一致，说明转发器没有吞掉退出码
```

---

## 七、踩过的坑

### 坑 1：`NO_PROXY` 不能漏

漏了它，应用自己的本地页面会走代理：

```
本地服务 127.0.0.1:18080
  direct    → 200
  via proxy → 502   ← 必然失败
```

### 坑 2：注册表 PATH 的类型

`HKCU:\Environment\Path` 有两个陷阱：

```powershell
# 错误：GetValue() 默认会展开 %LOCALAPPDATA%，写回后变成硬编码路径
$raw = $key.GetValue('Path')

# 错误：Set-ItemProperty 写入的类型变成 String，丢失 ExpandString
Set-ItemProperty ... -Value $new

# 正确
$raw = $key.GetValue('Path', '',
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
[Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\Environment', 'Path',
        $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
```

验证：

```powershell
(Get-Item 'HKCU:\Environment').GetValueKind('Path')   # 应为 ExpandString
```

### 坑 3：PowerShell 执行策略挡住 profile

```
无法加载文件 ...\profile.ps1，因为在此系统上禁止运行脚本
```

原因：策略为 `Restricted`，而 `profile.ps1` 里有初始化脚本（如 conda init）。

```powershell
Get-ExecutionPolicy -List
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

`RemoteSigned` = 本地脚本可运行，下载的必须签名。这是微软推荐的日常开发档位。

### 坑 4：程序升级会冲掉转发器吗

不会。升级只替换原始程序的 `bin\app.exe`，转发器在 `shim\` 目录，路径独立。实测从 1.5.2 升到 1.5.3，转发器完好。

### 坑 5：`netsh winhttp set proxy` 对 Go 无效

很多人以为设置系统级 WinHTTP 代理就能解决问题：

```powershell
netsh winhttp set proxy 127.0.0.1:7897    # ← 对 Go 程序无效
```

Go 不读 WinHTTP 配置。**环境变量是唯一途径**（除非使用 TUN 类透明代理）。

---

## 八、方案对比

| 方案 | 侵入性 | 覆盖面 | 主要问题 |
|---|---|---|---|
| 全局环境变量（`setx`） | 高 | 全系统 | 代理一关即全系统断网；本地服务 502 |
| **进程级注入（本文）** | 低 | 仅目标程序 | 需为每个程序单独配置 |
| TUN / 透明代理 | 中 | 全系统 | 需装虚拟网卡驱动；与部分游戏反作弊存在兼容风险 |
| `netsh winhttp` | 中 | WinHTTP 程序 | **Go 不认，无效** |

---

## 九、这次排查的可复用经验

1. **Electron 应用的本地页面超时，先怀疑内核进程**
   本地地址超时 ≠ 本地服务坏了。去看看同目录下的 `language_server.log` / `main.log` / `renderer.log`。

2. **`dial tcp ... i/o timeout` 是 Go 的特征**
   Go 的 `net.Dial` 报错格式很有辨识度。看到它就知道：这个进程是 Go 写的，它在直连。

3. **双进程架构的日志要分开看**
   Electron 外壳和内核的日志是分开的，症状在外壳，根因常在核。

4. **环境变量 vs 系统设置的差异**
   Go / Rust / 部分 Node 工具链只认环境变量。这是跨平台排查的基础知识。

---

## 参考

- Go `net/http.ProxyFromEnvironment`：仅从环境变量读取代理配置
- Electron 多进程架构与日志位置约定
- Windows `HKEY_CURRENT_USER\Environment` 注册表值类型（`String` vs `ExpandString`）
