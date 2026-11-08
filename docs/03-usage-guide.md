# Antigravity 国内使用完全指南

> **适用版本**：Antigravity 2.29.1（桌面版）· Antigravity CLI (agy) 1.5.3
> **适用系统**：Windows 10 / 11
> **最后更新**：2026-11-08
> **适用人群**：中国大陆用户，已有 Google 账号和可用的网络代理

---

## 目录

1. [这是什么](#一这是什么)
2. [前置条件](#二前置条件)
3. [安装](#三安装)
4. [核心问题：代理配置](#四核心问题代理配置)
5. [桌面版使用](#五桌面版使用)
6. [命令行版（agy）使用](#六命令行版agy使用)
7. [常见问题排查](#七常见问题排查)
8. [账号安全](#八账号安全)
9. [附录：文件位置速查](#九附录文件位置速查)

---

## 一、这是什么

Antigravity 是 Google 推出的 AI 编程工具，有**两个入口**：

| 形态 | 程序 | 特点 |
|---|---|---|
| **桌面版** | `Antigravity.exe` | Electron 应用，图形界面，类似 Cursor |
| **命令行版** | `agy.exe` | 终端 TUI，类似 Claude Code / Gemini CLI |

两者**共用同一套账号和凭据**，登录一次两边都通。

### 1.1 可用模型

实测当前可用的模型（`agy models`）：

```
gemini-3.8-flash-high      Gemini 3.8 Flash (High)
gemini-3.8-flash-medium    Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low       Gemini 3.8 Flash (Low)
claude-sonnet-4-6          Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking   Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium        GPT-OSS 120B (Medium)
```

> **注意**：`gemini-3.8-flash-*` 系列型号名里已经带了推理档位（high/medium/low）。如果再单独指定 `--effort`，会报冲突错误：
> ```
> error: --model gemini-3.8-flash-high conflicts with --effort=low
> ```
> 用这些模型时**不要**再加 `--effort`。

### 1.2 架构：为什么会有"本地页面超时"这种事

理解这一点，能帮你快速定位 90% 的问题：

```
Antigravity.exe          ← Electron 外壳（窗口、UI）
    └─ language_server.exe   ← Go 内核（登录、API、状态）
```

**两个进程，两套网络行为**：

| 组件 | 认 Windows 系统代理？ | 认环境变量？ |
|---|---|---|
| Electron 外壳 | ✅ 认 | ✅ 认 |
| Go 内核 | ❌ **完全不认** | ✅ 认 |

这就是**"浏览器能上 Google，但 Antigravity 卡住"**的根本原因，也是本指南第四章要解决的问题。

---

## 二、前置条件

### 2.1 必须有的

| 项目 | 要求 |
|---|---|
| **Google 账号** | 能正常登录即可。有 **Google AI Pro** 订阅体验更好（更高额度、更强模型） |
| **网络代理** | 能访问 `googleapis.com`、`google.com`、`gstatic.com` |
| 操作系统 | Windows 10 1809+ / Windows 11 |
| 磁盘空间 | 约 1.5 GB（两个程序加起来） |

### 2.2 关于地区限制

**实测结论：没有区域封锁。**

我检查了 `agy.exe` 和 `language_server.exe` 的二进制文件，搜索 `unsupported region` / `not available in your country` / `embargo` 等关键字，**没有找到任何区域限制逻辑**。

`China` 这个词在二进制里出现过 2 次，都是 Windows 时区列表里的 `China Standard Time`，与限制无关。

所以：**用代理把流量导到境外节点后，功能完全可用。**

### 2.3 代理要求

这条很重要，很多人在这里出错：

> **代理必须是「能处理 HTTPS 的 HTTP 代理」或「支持 TUN 的透明代理」。**

常见的代理客户端（Clash Verge、Clash for Windows、v2rayN 等）都提供 `mixed-port`（混合端口，同时支持 HTTP 和 SOCKS5）。

你要记住**这个端口号**，后面配置要用。查法：

```powershell
netstat -ano | findstr LISTENING | findstr "127.0.0.1:789"
```

常见默认值：

| 客户端 | 默认端口 |
|---|---|
| Clash Verge Rev | `7897` |
| Clash for Windows | `7890` |
| v2rayN | `10809`（HTTP）/ `10808`（SOCKS） |

---

## 三、安装

### 3.1 桌面版

从官方下载安装包，默认安装到：

```
%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe
```

装完**先不要急着打开**，先做第四章的代理配置，否则会卡在加载页面。

### 3.2 命令行版

`agy` 通常在安装桌面版时一起安装，位置：

```
%LOCALAPPDATA%\agy\bin\agy.exe
```

验证：

```powershell
agy --version
# 应输出：1.5.3
```

如果提示「不是内部或外部命令」，说明 PATH 里没有，需要手动加（见 7.5 节）。

---

## 四、核心问题：代理配置

> **这一章是本指南最重要的部分。跳过它，两个程序都用不了。**

### 4.1 问题现象

如果你只开了代理软件的「系统代理」而没做额外配置，会看到：

**命令行版：**
```
Got an error: token exchange failed: Post "https://oauth2.googleapis.com/token":
dial tcp 173.194.203.95:443: connectex: A connection attempt failed...
```

**桌面版：**
一直转圈，日志里是：
```
[error] electron: Failed to load URL: https://127.0.0.1:12111/
        with error: ERR_TIMED_OUT
```

**注意这个 `127.0.0.1`** —— 它是本机地址，但根因在远端。**不要重装软件**，那不是本地服务的问题。

### 4.2 原因

`agy` 和 Antigravity 的 Go 内核，**只读取环境变量** `HTTP_PROXY` / `HTTPS_PROXY`，**不读 Windows 系统代理设置**。

而大多数代理软件默认只开启「系统代理」，所以：

```
浏览器 → 读系统代理 → ✅ 能上 Google
agy   → 不读系统代理 → 直连 → ❌ 超时
```

### 4.3 ❌ 不要这样做

```powershell
# 不要用这个方案！
setx HTTPS_PROXY "http://127.0.0.1:7897"
setx HTTP_PROXY  "http://127.0.0.1:7897"
```

**为什么不推荐**，四个具体问题：

1. **本地服务会挂**：任何访问 `127.0.0.1` 的请求都送进代理 → 502
2. **内网设备失灵**：`192.168.*`、`10.*` 网段全走代理
3. **单点故障**：代理一关，**整个系统断网**，包括你的 IDE、包管理器
4. **难以排查**：以后遇到网络问题很难想到是这个变量

### 4.4 ✅ 正确做法：只给这两个程序注入

原理：不修改任何全局设置，只在**启动那一刻**把代理变量传给需要它的进程。

```
普通程序 ──直连──> 不受影响
Antigravity / agy ──注入变量──> 127.0.0.1:7897
```

#### 4.4.1 桌面版配置

**第一步：创建启动器**

在任意位置新建文件 `Antigravity-Proxy.cmd`（建议放 `%USERPROFILE%\.agy-shim\`）。

⚠️ **必须用 ANSI 或纯英文内容保存**，否则中文 Windows 下 cmd 会解析乱码报错。

```bat
@echo off
REM Antigravity launcher WITH proxy (for this app only)

setlocal

REM ---- 改这里：你的代理端口 ----
if not defined ANTIGRAVITY_PROXY set "ANTIGRAVITY_PROXY=http://127.0.0.1:7897"

REM 本地回环绝不能走代理（关键！）
set "NO_PROXY=localhost,127.0.0.1,::1"
set "no_proxy=localhost,127.0.0.1,::1"

set "HTTPS_PROXY=%ANTIGRAVITY_PROXY%"
set "HTTP_PROXY=%ANTIGRAVITY_PROXY%"
set "https_proxy=%ANTIGRAVITY_PROXY%"
set "http_proxy=%ANTIGRAVITY_PROXY%"

set "APP=%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe"

if not exist "%APP%" (
    echo [ERROR] Antigravity.exe not found
    echo   expected: %APP%
    pause
    exit /b 1
)

start "" "%APP%"

endlocal
```

> **`NO_PROXY` 这一行不能漏。** 不设它，Antigravity 自己的本地页面（`https://127.0.0.1:端口/`）也会走代理，同样是超时。

**第二步：改快捷方式指向启动器**

```powershell
$launcher = "$env:USERPROFILE\.agy-shim\Antigravity-Proxy.cmd"
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
    $s.WindowStyle      = 7              # 最小化，避免黑框闪
    $s.Save()
    Write-Host "已更新: $t"
}

# 改完必须逐一验证 —— 批量修改最容易漏掉其中一个
$bad = 0
foreach ($t in $targets) {
    if (-not (Test-Path $t)) { continue }
    $target = $sh.CreateShortcut($t).TargetPath
    if ($target -like '*.cmd') {
        Write-Host "  OK   $t" -ForegroundColor Green
    } else {
        Write-Host "  FAIL $t -> $target" -ForegroundColor Red
        $bad++
    }
}
if ($bad) { Write-Warning "$bad 个快捷方式未生效，请重跑本步骤" }
```

改完后，**双击桌面图标就能正常启动**，和以前一样。

> ⚠️ **别跳过下面的验证输出。** 实测遇到过「桌面改好了、开始菜单被更新器还原」的情况——从桌面启动正常，从开始菜单启动原故障完整复发。两个入口指向不同是极难排查的坑。

#### 4.4.2 命令行版配置

命令行版更复杂一点，因为它是交互式程序，可能被各种方式调用（终端、IDE、Python 脚本）。用 `.cmd` 中间层会出问题（退出码丢失、TUI 花屏）。

**方案：编译一个转发器**

需要 MinGW-w64（装过 VS Code C++ 环境、MSYS2、Chocolatey 的都有）。

**第一步：保存源码**

`shim.c`：

```c
/*
 * shim: 只给 agy 注入代理环境变量，其它程序完全不受影响。
 * 1. 环境已有 HTTPS_PROXY -> 原样放行
 * 2. 否则探测端口，通了就注入
 * 3. 都不通就不注入，保持原生行为
 * 4. 参数透传，退出码原样返回
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
    const wchar_t *c = wcsrchr(url, L':');
    return c ? (unsigned short)wcstoul(c + 1, NULL, 10) : 0;
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

    cl = GetEnvironmentVariableW(L"AGY_PROXY", custom, 512);
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

    if (GetEnvironmentVariableW(L"NO_PROXY", NULL, 0) == 0 &&
        GetEnvironmentVariableW(L"no_proxy", NULL, 0) == 0)
        SetEnvironmentVariableW(L"NO_PROXY", L"localhost,127.0.0.1,::1");
}

int main(void)
{
    wchar_t self[MAX_PATH], base[MAX_PATH], real[MAX_PATH];
    wchar_t *slash;
    const wchar_t *cmdline, *rest;
    wchar_t *full;
    size_t need;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    WSADATA wsa;

    if (!GetModuleFileNameW(NULL, self, MAX_PATH))
        return 1;

    wcsncpy(base, self, MAX_PATH - 1);
    base[MAX_PATH - 1] = 0;
    slash = wcsrchr(base, L'\\');
    if (slash)
        *slash = 0;

    real[0] = 0;
    {
        wchar_t probe[MAX_PATH];
        DWORD cl = GetEnvironmentVariableW(L"AGY_REAL_EXE", probe, MAX_PATH);
        if (cl > 0 && cl < MAX_PATH &&
            GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
            wcsncpy(real, probe, MAX_PATH - 1);

        if (!real[0]) {
            _snwprintf(probe, MAX_PATH, L"%s\\bin\\agy.exe", base);
            probe[MAX_PATH - 1] = 0;
            if (GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
                wcsncpy(real, probe, MAX_PATH - 1);
        }
    }
    real[MAX_PATH - 1] = 0;

    if (!real[0])
        return 1;

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

**第二步：编译**

```powershell
# 建目录
New-Item -ItemType Directory -Force -Path "$env:LOCALAPPDATA\agy\shim"

# 编译
gcc -O2 -s -Wall -o "$env:LOCALAPPDATA\agy\shim\agy.exe" shim.c -lws2_32
```

产物约 18 KB。

**第三步：加入 PATH 最前面**

```powershell
$shimDir = '%LOCALAPPDATA%\agy\shim'
$key = Get-Item 'HKCU:\Environment'

# 关键：必须用 DoNotExpandEnvironmentNames
# 否则 %LOCALAPPDATA% 会被展开成硬编码路径
$raw = $key.GetValue('Path', '',
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

$parts = $raw -split ';' | Where-Object { $_.Trim() -ne '' }
$new = (@($shimDir) + $parts) -join ';'

[Microsoft.Win32.Registry]::SetValue(
    'HKEY_CURRENT_USER\Environment', 'Path', $new,
    [Microsoft.Win32.RegistryValueKind]::ExpandString)   # 必须保持 ExpandString
```

**改完必须重开终端**（PATH 是进程启动时读取的）。

最终结构：

```
%LOCALAPPDATA%\agy\
  ├─ shim\agy.exe     ← 转发器（PATH 最前）
  └─ bin\agy.exe      ← 原始程序（不动）
```

### 4.5 验证配置成功

```powershell
# 1. 确认解析到 shim
(Get-Command agy).Source
# 应输出：C:\Users\xxx\AppData\Local\agy\shim\agy.exe

# 2. 确认全局没被污染
[Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')
# 应输出：空

# 3. 确认 agy 能用
agy -p "reply with exactly: OK"
# 应输出：OK
```

桌面版：

```powershell
# 看日志有没有网络错误
Select-String -Path "$env:APPDATA\Antigravity\logs\language_server.log" -Pattern "dial tcp"
# 应该没有输出
```

---

## 五、桌面版使用

### 5.1 首次启动

1. 双击 **桌面图标**（已指向启动器）
2. 等待加载，正常应该 **2~5 秒**进入欢迎界面
3. 如果超过 30 秒还在转圈，见第七章

正常启动后左下角能看到账号名和套餐（如 `(Google AI Pro)`）。

### 5.2 界面结构

| 区域 | 功能 |
|---|---|
| 左侧栏 | 会话列表、项目（Projects）、历史对话 |
| 中间 | 对话区 |
| 底部 | 输入框、模型选择、附加文件 |

### 5.3 常用操作

**新建会话**：左上角 `+ New Conversation`

**切换项目**：左侧 `Projects` 下点击具体项目。不同项目的上下文是隔离的。

**附加文件**：输入框 `@` 符号可以引用工作区文件。

**历史会话**：左侧 `Conversations`，点击恢复。

### 5.4 与 CLI 共用账号

桌面版和 CLI 用**同一套 Google 凭据**（存在系统密钥链里）。

所以：
- 在任一边重新登录，另一边也会同步
- 如果一边提示权限不足，另一边大概率也一样

---

## 六、命令行版（agy）使用

### 6.1 首次登录

```powershell
agy
```

会引导你在浏览器授权。如果浏览器打不开，会给你一个链接手动复制。

**登录成功后**，当前目录下直接进入交互界面。

### 6.2 基本交互

```
> 帮我看看这个项目的结构
> 这个函数有什么问题？
> 给这段代码加注释
```

**多行输入**：`Shift+Enter` 换行，`Enter` 提交。

**中断**：`Ctrl+C`

**退出**：`Ctrl+D` 或输入 `/quit`

### 6.3 常用斜杠命令

| 命令 | 作用 |
|---|---|
| `/help` | 帮助 |
| `/clear` | 清空当前对话上下文 |
| `/compact` | 压缩上下文（长对话变长时用） |
| `/model` | 切换模型 |
| `/models` | 列出可用模型 |
| `/cost` | 查看本次会话用量 |
| `/login` / `/logout` | 登录/登出 |
| `/resume` | 恢复上次会话 |
| `/init` | 初始化项目配置（生成 AGENTS.md） |
| `/mcp` | 管理 MCP 服务器 |
| `/plugin` | 管理插件 |
| `/skills` | 查看技能 |
| `/agents` | 查看子代理 |
| `/memory` | 管理记忆 |
| `/undo` | 撤销上一步操作 |
| `/diff` | 查看改动差异 |
| `/status` | 查看状态 |
| `/version` | 版本 |

### 6.4 命令行参数

```powershell
# 单次提问（不进入交互）
agy -p "解释一下这段正则"

# 带模型的单次提问
agy -p "写一个快排" --model claude-sonnet-4-6

# 指定推理档位（注意：模型名已含档位的不要再加）
agy -p "分析这个 bug" --effort high

# 继续上次对话
agy --continue

# 新增工作目录（可多次）
agy --add-dir "D:\projects\foo"

# 自动批准所有工具权限（危险，谨慎用）
agy --dangerously-skip-permissions

# 只读模式（防止改文件）
agy --mode plan

# 沙箱模式
agy --sandbox

# 流式 JSON 输出（适合脚本调用）
agy -p "统计代码行数" --output-format stream-json

# 结构化输出（强制 JSON schema）
agy -p "提取函数名" --json-schema '{"type":"object","properties":{"names":{"type":"array","items":{"type":"string"}}}}'
```

### 6.5 执行模式（`--mode`）

| 模式 | 行为 |
|---|---|
| `plan` | 只读，**不改任何文件**，只给方案 |
| `accept-edits` | 自动接受文件修改 |
| `auto` | 自动决定（默认） |

**建议**：不熟悉的任务先用 `--mode plan` 看看它想干什么。

### 6.6 推理档位（`--effort`）

```
low | medium | high | xhigh | max
```

- `low`：快，简单任务
- `medium`：平衡
- `high` / `xhigh`：复杂推理
- `max`：最慢，最难的问题

> ⚠️ **冲突警告**：`gemini-3.8-flash-high` 这类模型名已含档位，不要再加 `--effort`，否则报错。

### 6.7 子命令

```powershell
agy models          # 列出可用模型
agy agents          # 列出子代理
agy plugins         # 列出插件
agy mcp list        # 列出 MCP 服务器
agy update          # 升级 CLI
agy changelog       # 查看更新日志
```

### 6.8 配置文件

位置：`%USERPROFILE%\.gemini\antigravity-cli\settings.json`

```json
{
  "colorScheme": "tokyo night",
  "trustedWorkspaces": [
    "C:\\Users\\你的用户名"
  ]
}
```

可配置项（实测支持）：

| 键 | 说明 |
|---|---|
| `colorScheme` | 主题配色 |
| `trustedWorkspaces` | 受信任的工作目录（免确认） |
| `defaultModel` | 默认模型 |
| `showTips` | 是否显示提示 |
| `vimMode` | Vim 键位 |
| `fontSize` | 字号 |

---

## 七、常见问题排查

### 7.1 桌面版一直转圈进不去

**这是最常见的问题。**

**排查顺序**：

**第一步：看代理开没开**

```powershell
netstat -ano | findstr "127.0.0.1:7897"
```

有输出 = 代理在跑。没输出 = 先去开代理软件。

**第二步：看日志**

```powershell
# 内核日志（最关键）
Get-Content "$env:APPDATA\Antigravity\logs\language_server.log" -Tail 20

# 外壳日志
Get-Content "$env:APPDATA\Antigravity\logs\main.log" -Tail 20
```

**关键字对照**：

| 日志里出现 | 含义 | 解决 |
|---|---|---|
| `dial tcp ... i/o timeout` | 内核在直连，没走代理 | 第四章的配置没生效 |
| `ERR_TIMED_OUT` | 本地页面加载失败 | 通常上一条的连锁反应 |
| `ACCESS_TOKEN_SCOPE_INSUFFICIENT` | 登录 token 权限不全 | 见 7.2 |
| `connection refused` | 代理端口不通 | 检查端口号是否对 |

**第三步：确认是不是启动器生效了**

```powershell
# 看当前 Antigravity 进程的命令行
Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'Antigravity.exe'} | Select-Object -First 1 -ExpandProperty CommandLine
```

如果进程存在但还在转圈，说明启动器被绕过了（比如从开始菜单的旧快捷方式启动）。

### 7.2 提示 "Sign-in update needed"

```
⚠ Sign-in update needed
  Your sign-in is missing permissions that are now required,
  so some requests may fail. Run /logout to sign in again.
```

**原因**：你的登录 token 是**旧版本**签发的，缺少新版本要求的 OAuth 权限范围（scope）。

**日志特征**：
```
403 Forbidden, "Request had insufficient authentication scopes."
reason: ACCESS_TOKEN_SCOPE_INSUFFICIENT
```

**解决**：

```powershell
# 命令行版
agy
/logout
# 然后重新登录
```

桌面版：在界面里退出账号再登录。

**注意**：两个程序共用凭据，**在一个地方重新登录，另一边也会同步解决**。

**验证是否真的解决了**：重登后不要只看界面警告消失，要查日志确认。

```powershell
# 清空旧日志（避免残留干扰判断）
Remove-Item "$env:APPDATA\Antigravity\logs\*.log"

# 重启 Antigravity，等 30 秒后查
Select-String "$env:APPDATA\Antigravity\logs\language_server.log" -Pattern "SCOPE_INSUFFICIENT"
# 无输出 = 已解决
```

**实测确认**：重登后 `SCOPE_INSUFFICIENT` 从 1 降为 **0**，`Auth succeeded` 出现 1 次，全部 E/W 级错误归零。

> ⚠️ **如果重登后仍报 403**：可能是账号本身没有对应功能的权限（如未订阅 AI Pro），或代理节点 IP 被判定异常。先确认订阅状态，再检查 IP 质量（见第八章）。

### 7.3 agy 报 `token exchange failed`

**原因**：代理没生效，直连 Google 超时。

**解决**：检查第四章的 shim 是否配置正确。

```powershell
(Get-Command agy).Source
# 应该是 ...\agy\shim\agy.exe 而不是 ...\agy\bin\agy.exe
```

### 7.4 ⚠️ 症状对照：修复失效 vs 节点故障

**这一节非常重要**，因为这两种情况看起来一样，但处理方式完全不同。

agy 超时，可能是两个原因：

| 症状 | 原因 | 怎么判断 | 怎么处理 |
|---|---|---|---|
| 所有 Google 域名都不通 | **修复失效**（没走代理） | `agy --version` 无输出 / 解析位置是 `bin\` | 重新配置第四章 |
| **只有 cloudcode-pa 不通，其它域名正常** | **节点故障** | 见下方诊断命令 | **换节点**，不用改配置 |

#### 诊断命令：一条命令区分两者

```powershell
# 逐域名测试（走代理）
'cloudcode-pa.googleapis.com',
'daily-cloudcode-pa.googleapis.com',
'oauth2.googleapis.com',
'accounts.google.com' | ForEach-Object {
    $code = curl.exe -x http://127.0.0.1:7897 -s -o NUL -w "%{http_code}" --max-time 8 "https://$_/"
    "{0,-40} {1}" -f $_, $code
}
```

**结果解读**：

```
✓ 全都是 404/302/204（有响应）        → 一切正常
✗ 全部 000（超时）                     → 修复失效，回去查第四章
✗ 只有 cloudcode-pa 系列 000          → 节点对上游故障，换节点
```

#### 为什么会出现「只有 cloudcode-pa 不通」

agy 拉取模型列表、发起对话，走的都是 `cloudcode-pa.googleapis.com` 这个域名。

代理节点本身能出网（所以 `google.com` 正常），但**节点到 Google 这个特定上游的链路有问题**——常见于：

- 该 IP 被 Google 限流
- 节点中转服务器到 Google 的线路拥塞
- 订阅节点本身"半死"（TCP 通但实际丢包）

**这不是配置问题，换一个节点就好。**

#### 怎么换节点

在你的代理客户端里：

1. 找到承载 Google 流量的那个策略组（通常是手动固定的那个）
2. 换到另一个节点
3. 再跑一次上面的诊断命令确认

> **注意**：`shim` 只负责保证「流量走代理」，**不保证「代理能出网」**。节点健康需要你自己监控。

#### 一个真实的例子

实测遇到过：

```
cloudcode-pa.googleapis.com          000  ← 超时
daily-cloudcode-pa.googleapis.com    000  ← 超时
oauth2.googleapis.com                404  ← 正常
accounts.google.com                  302  ← 正常
www.google.com                       200  ← 正常
```

当时 agy 完全不可用（`Error: timed out waiting for available models`，耗时 40+ 秒）。

**换节点后立刻恢复**，3 秒内返回模型列表。

配置一行没动。

### 7.5 显示了模型列表但对话报错

可能是账号额度或订阅问题。检查：

```powershell
agy
/cost      # 查看用量
/status    # 查看状态
```

免费账号额度较低，可能触发限流。**Google AI Pro** 订阅额度明显更高。

### 7.6 `agy` 命令找不到

说明 PATH 里没有。检查：

```powershell
$env:PATH -split ';' | Select-String "agy"
```

**手动添加**（管理员或当前用户）：

```powershell
# 图形界面
rundll32 sysdm.cpl,EditEnvironmentVariables

# 或命令行
$p = [Environment]::GetEnvironmentVariable('Path','User')
[Environment]::SetEnvironmentVariable('Path', "$env:LOCALAPPDATA\agy\shim;$env:LOCALAPPDATA\agy\bin;$p", 'User')
```

改完重开终端。

### 7.7 PowerShell 启动时报"禁止运行脚本"

```
无法加载文件 ...\profile.ps1，因为在此系统上禁止运行脚本
```

**原因**：执行策略是 `Restricted`。

**解决**：

```powershell
Get-ExecutionPolicy -List
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

`RemoteSigned` = 本地脚本可跑，下载的必须签名。这是微软推荐的日常档位。

### 7.8 升级后快捷方式失效

Antigravity 有自动更新。如果更新后发现又卡住了：

```powershell
# 重新指向启动器
# 把 4.4.1 节第二步的脚本再跑一遍
```

`agy` 升级**不会**影响 shim（两者在不同目录）。

### 7.9 桌面版页面能开但功能报错

看这个日志：

```powershell
Get-Content "$env:APPDATA\Antigravity\logs\language_server.log" -Tail 50 | Select-String "403|error|failed"
```

对照：

| 错误 | 原因 |
|---|---|
| `insufficient authentication scopes` | 重新登录（见 7.2） |
| `quota exceeded` / `rate limit` | 额度用完，等待或升级订阅 |
| `deadline exceeded` | 网络慢，换个节点试试 |

---

## 八、账号安全

### 8.1 会被封号吗？

**诚实回答：不能说绝对零风险，但正常使用风险很低。**

Google 封号的主要触发因素是**自动化滥用、ToS 违规、支付欺诈、批量注册**，不是"你用了代理"。

代理相关的实际影响通常是：

```
CAPTCHA 验证 → 二次验证 → 临时限制 → 才可能升级
```

**你会收到多次提醒，有一到多次机会调整。**

### 8.2 真实的风险因素（按重要性）

| 因素 | 风险 | 说明 |
|---|---|---|
| **IP 频繁跨国跳变** | ⭐⭐⭐⭐⭐ | 最高危。5 分钟内从台北跳到洛杉矶，任何系统都会标记 |
| **机房 IP** | ⭐⭐⭐⭐ | `hosting=true` 的 IP 风险显著更高 |
| **多账号来回切** | ⭐⭐⭐⭐ | 账号关联风控 |
| **脚本高频刷 API** | ⭐⭐⭐⭐ | 自动化行为判定 |
| **共享 IP 被滥用** | ⭐⭐⭐ | 同一出口多人共用，他人行为影响 IP 信誉 |
| 支付地区与 IP 不一致 | ⭐⭐ | 弱信号，非常普遍 |

### 8.3 检查你的 IP 质量

```powershell
curl.exe -x http://127.0.0.1:7897 -sS "http://ip-api.com/json/?fields=query,country,isp,proxy,hosting"
```

关注两个字段：

- `proxy`：是否被标记为代理 IP
- `hosting`：是否是机房 IP

**理想状态：两个都是 `false`**，且 `isp` 是住宅宽带运营商（电信、联通、中华电信等）。

### 8.4 检查 IP 稳定性

```powershell
for ($i=1; $i -le 5; $i++) {
    curl.exe -x http://127.0.0.1:7897 -sS "http://ip-api.com/line/?fields=query"
    Start-Sleep 5
}
```

**5 次应该完全一致。** 如果一直在变，说明节点在自动切换 —— 这是最需要修复的风险点。

### 8.5 降低风险的做法

**必做**：

1. **固定节点**，不要让策略组指向「自动选择」（URLTest 类型会自己跳）
2. **一次配好，不要反复切模式或换节点**
3. 保持登录凭据完整（修掉旧 token）

**建议**：

4. 同一时刻只在一个客户端活跃
5. 不用免费/试用节点跑主账号
6. 尽量长期使用同一个节点

**别做**：

- 频繁切节点
- 多账号来回登
- 脚本高频刷 API
- 分享账号给别人（异地登录直接触发风控）

### 8.6 自检标准

> **过去一周没有被要求「重新登录」或「验证手机」→ IP 环境稳定，风险很低。**

如果验证码明显变多、经常要求重新登录，先检查节点是不是在飘。

---

## 九、附录：文件位置速查

### 9.1 程序位置

| 程序 | 路径 |
|---|---|
| 桌面版 | `%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe` |
| Go 内核 | `%LOCALAPPDATA%\Programs\antigravity\resources\bin\language_server.exe` |
| 命令行版 | `%LOCALAPPDATA%\agy\bin\agy.exe` |

### 9.2 配置与数据

| 类型 | 路径 |
|---|---|
| **桌面版日志** | `%APPDATA%\Antigravity\logs\main.log` |
| **内核日志** | `%APPDATA%\Antigravity\logs\language_server.log` |
| 桌面版用户数据 | `%APPDATA%\Antigravity\` |
| **agy 日志** | `%USERPROFILE%\.gemini\antigravity-cli\cli.log` |
| **agy 设置** | `%USERPROFILE%\.gemini\antigravity-cli\settings.json` |
| agy 会话历史 | `%USERPROFILE%\.gemini\antigravity-cli\conversations\` |
| agy 项目配置 | `%USERPROFILE%\.gemini\config\config.json` |
| IDE 数据 | `%USERPROFILE%\.gemini\antigravity-ide\` |

### 9.3 日志里的关键行怎么读

**内核日志**（`language_server.log`）：

```
I1108 15:07:34.647989  server.go:1888] Starting language server process with pid 16452
```
→ 正常启动

```
W auth_client.go:415] Failed to get granted scopes in validation:
failed to call tokeninfo: ... dial tcp 172.217.115.4:443: i/o timeout
```
→ **代理没生效**，内核在直连

```
W code_assist_client.go:228] AICode FetchConfig failed:
"403 Forbidden", "Request had insufficient authentication scopes."
```
→ 登录 token 权限不全，需重新登录

```
I server.go:746] Language server listening on random port at 6016 for HTTPS
I server.go:754] Language server listening on random port at 6012 for HTTP
```
→ 正常监听，本地端口是随机的

**外壳日志**（`main.log`）：

```
[info] Local: https://127.0.0.1:8860/
```
→ 当前 UI 地址

```
[error] electron: Failed to load URL: https://127.0.0.1:8860/ with error: ERR_TIMED_OUT
```
→ **核心里程碑**，通常是内核连不上 Google 导致

```
[AutoUpdater] Up to date (2.29.1)
```
→ 更新检查正常（说明 Electron 网络栈也通）

### 9.4 常用排查命令速查

```powershell
# 代理端口是否在监听
netstat -ano | findstr "127.0.0.1:789"

# 测试走代理能不能通
curl.exe -x http://127.0.0.1:7897 -sS -m 10 -o NUL -w "%{http_code}`n" https://www.google.com/generate_204

# 测试直连（应该失败，验证代理确实在用）
curl.exe --noproxy '*' -sS -m 8 -o NUL -w "%{http_code}`n" https://www.google.com

# 查出口 IP
curl.exe -x http://127.0.0.1:7897 -sS "http://ip-api.com/json/?fields=query,country,isp,proxy,hosting"

# 看有没有直连外网（应该只有 127.0.0.1:7897）
$pids = Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'Antigravity|language_server' } | Select-Object -ExpandProperty ProcessId
Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $pids -contains $_.OwningProcess } | Select-Object RemoteAddress,RemotePort | Sort-Object -Unique

# agy 解析位置
(Get-Command agy).Source

# 全局代理变量（应为空）
foreach($n in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY'){ "$n = " + [Environment]::GetEnvironmentVariable($n,'User') }
```

---

## 十、快速上手清单

新装机的完整流程：

```
□ 1. 安装 Antigravity 桌面版
□ 2. 确认代理软件在运行，记住端口号（如 7897）
□ 3. 创建 Antigravity-Proxy.cmd 启动器（4.4.1）
□ 4. 改快捷方式指向启动器 —— 桌面 + 开始菜单【两处都要】
□ 5. 验证两处都生效（见下方命令）
□ 6. 编译 agy shim（4.4.2）
□ 7. 把 shim 加入 PATH 最前
□ 8. 重开终端
□ 9. 验证：agy -p "reply OK"
□ 10. 验证：(Get-Command agy).Source 指向 shim
□ 11. 双击桌面图标，确认 2-5 秒进入界面
□ 12. agy 里 /logout 再重新登录（清掉旧 token）
□ 13. 重登后查日志确认 SCOPE_INSUFFICIENT 为 0（见 7.2）
□ 14. 固定代理节点，不要用「自动选择」
```

全部完成约需 **15-20 分钟**（编译 shim 需要一点时间）。

### 第 5 步：一次性验证所有快捷方式

**这一步不能省。** 实测案例：曾出现「桌面快捷方式改好了、开始菜单被更新器还原」的情况——从桌面启动正常，从开始菜单启动原故障完整复发，极难排查。

```powershell
$sh = New-Object -ComObject WScript.Shell
$paths = @(
    (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Agent\Antigravity.lnk'),   # 可能被移动过
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk')
)

$bad = 0
foreach ($p in $paths) {
    if (-not (Test-Path $p)) { continue }
    $target = $sh.CreateShortcut($p).TargetPath
    if ($target -like '*.cmd') {
        Write-Host "  ✅ $p" -ForegroundColor Green
    } else {
        Write-Host "  ❌ 未生效: $p  -> $target" -ForegroundColor Red
        $bad++
    }
}
if ($bad -gt 0) { Write-Warning "有 $bad 个快捷方式未指向启动器，请重跑第 4 步" }
```

### 定期自查（每月或每次大版本更新后）

Antigravity 的自动更新**可能重建快捷方式**，把指向还原成原始 exe。建议更新后跑一次上面的验证脚本。

如果发现被还原，重跑一次 `repoint-shortcut.ps1` 即可：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agy-shim\repoint-shortcut.ps1"
```

---

## 十一、小结

### 三个核心认知

1. **Go 程序不认系统代理**
   这是"浏览器能上、工具不行"的根本原因。

2. **本地页面超时，根因常常在远端**
   看到 `127.0.0.1` 超时，先去看同目录的 `language_server.log`，不要重装软件。

3. **进程级注入优于全局变量**
   范围越小、改动越少、可逆性越强，出问题越容易定位。

### 一句话备忘

> **代理要"注入"不要"全局"；节点要"固定"不要"自动"；登录要"完整"不要"残缺"。**

---

## 参考

- `Antigravity代理问题-博客版.md` —— 完整排查过程与技术细节
- `01-技术版-Go程序读不到系统代理.md` —— 纯技术原理
- `02-实践版-单程序代理配置.md` —— 方案对比与实现
- Go 官方文档：`net/http.ProxyFromEnvironment`
