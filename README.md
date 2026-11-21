# Antigravity Proxy Fix

> 让 Google Antigravity 桌面版和 Antigravity CLI (`agy`) 在中国大陆网络环境下正常工作

[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11%20%7C%20Ubuntu%20%2F%20Linux-blue)]()
[![Tested](https://img.shields.io/badge/tested-Antigravity%202.33%2B-green)]()
[![License](https://img.shields.io/badge/license-MIT-lightgrey)]()

---

## 问题是什么

Antigravity 和它的 CLI 在只开启代理软件「系统代理」时无法工作：

**表面症状**

```
# CLI
token exchange failed: Post "https://oauth2.googleapis.com/token":
dial tcp 173.194.203.95:443: connectex: A connection attempt failed...
```

```
# 桌面版 —— 白屏/转圈，看起来像本地服务坏了
electron: Failed to load URL: https://127.0.0.1:12111/ with error: ERR_TIMED_OUT
```

**真实原因**

Antigravity 是双进程架构：

```
Antigravity.exe          ← Electron 外壳（认 Windows 系统代理）
    └─ language_server.exe   ← Go 内核（只认环境变量，不认系统代理）
```

Go 的 `net/http` 通过 `http.ProxyFromEnvironment` 获取代理配置，**唯一来源是环境变量**。它不读注册表、不读 WinHTTP、不读 PAC。

所以：**浏览器能上 Google，但这两个程序在直连 → 超时 → 卡死。**

---

## 解决方案

**只给目标程序注入代理环境变量，不污染全局。**

```
普通程序 ──直连──> 不受影响
Antigravity / agy ──注入 HTTPS_PROXY──> 127.0.0.1:7897
```

| 方案 | 侵入性 | 适用范围 |
|---|---|---|
| **进程级注入（本仓库）** | 低，仅目标程序 | ✅ 推荐 |
| 全局环境变量 `setx` | 高，全系统 | ❌ 代理一关全系统断网 |
| TUN 模式 | 中，需装驱动 | ⚠️ 与游戏反作弊可能冲突 |

---

## 代理端口与查找优先级（不写死任何端口）

> 下文示例中的 `7897`、`7890` 仅为常见代理端口示例，实际请替换成**你自己的代理端口**（例如 v2rayN 常见 `10808`/`10809`，Clash 常见 `7897`/`7890`，局域网代理 `http://192.168.x.x:端口`，或 `socks5://127.0.0.1:1080`）。

Windows 启动器/CLI shim 与 Linux 包装器采用完全一致的 4 级解析顺序，**每次启动时都会先 TCP 探活再注入**（代理关闭时绝不误注入）：

| 优先级 | 来源 | 说明 |
|---|---|---|
| **1** | `HTTPS_PROXY` / `HTTP_PROXY`（含小写） | 终端当前已显式配置代理时，原样放行不覆盖 |
| **2** | `ANTIGRAVITY_PROXY`（桌面）/ `AGY_PROXY`（CLI） | 仅作用于本工具的专属环境变量，可写 URL 或纯端口号 |
| **3** | `proxy.conf` 配置文件 | Windows 位于 `%USERPROFILE%\.agy-shim\proxy.conf`；Linux 位于 `~/.config/agy-proxy/proxy.conf`（支持纯端口、`host:port`、`http://...`、`socks5://...`、`PROXY=...`） |
| **4** | `[fallback]` 默认回退探测 | **仅当上述配置未设置或均不可达时**，才依次回退探测 `127.0.0.1:7897` → `7890` → `10809` |

> 自检脚本在检查端口时，会优先探测你在 `proxy.conf` 中设置的地址并标注 `[from proxy.conf]`，`7897 / 7890 / 10809` 会明确标注为 `[fallback]`。

---

## 快速开始（Windows）

> 如首次运行 `.ps1` 遇到「在此系统上禁止运行脚本」，先执行：
> `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`
> 安装脚本会自动创建 `%USERPROFILE%\.agy-shim` 等所需目录，无需手动新建。

### 1. 桌面版（Antigravity）

**推荐方式（零 MinGW 依赖，兼容 Dashboard 内嵌栏 & 防开始菜单被通知还原）：**

```powershell
# 1) 用系统自带 csc.exe 编译无窗口启动器 AntigravityProxy.exe 到 %USERPROFILE%\.agy-shim\
#    将 7897 换成你的实际代理端口（写入 %USERPROFILE%\.agy-shim\proxy.conf）
powershell -ExecutionPolicy Bypass -File .\scripts\build-desktop-launcher.ps1 -ProxyUrl http://127.0.0.1:7897

# 2) 改写快捷方式指向 AntigravityProxy.exe（保留原有参数）
#    -AddDebugPort     : 补齐 Antigrative Dashboard / antigravity-pulse 内嵌栏所需本地调试端口
#    -ProtectStartMenu : 写回 Electron AppUserModelID 并对开始菜单快捷方式加只读(+R)，防止桌面通知静默还原
powershell -ExecutionPolicy Bypass -File .\scripts\repoint-shortcut.ps1 -AddDebugPort -ProtectStartMenu
```

> 后续修改代理端口只需编辑 `%USERPROFILE%\.agy-shim\proxy.conf`（或重跑 `build-desktop-launcher.ps1 -ProxyUrl http://127.0.0.1:<新端口>`），**无需重新改写快捷方式或重新编译**。

**传统 `.cmd` 方式（如仍希望使用纯批处理启动器）：**

```powershell
# 复制 src/Antigravity-Proxy.cmd（已支持 %* 参数透传）到 %USERPROFILE%\.agy-shim\ 并修改端口
# 然后运行 scripts/repoint-shortcut.ps1（会自动保留快捷方式现有参数）
powershell -ExecutionPolicy Bypass -File .\scripts\repoint-shortcut.ps1
```

**强烈建议同时装自愈脚本。** Antigravity 用 Squirrel/Electron 更新框架，每次更新会重建开始菜单快捷方式；运行时 Electron 的 Windows Toast 通知也会在 AUMID 不匹配时重写开始菜单快捷方式——自愈脚本会自动保留现有启动参数并写回 `electron.app.Antigravity`：

```powershell
# 自愈脚本放这里
Copy-Item .\scripts\self-heal-shortcuts.ps1 "$env:USERPROFILE\.agy-shim\"

# 启动项放这里（每次登录跑一次，无窗口；正常时不写任何东西）
Copy-Item .\scripts\self-heal-shortcuts.vbs `
  "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\"
```

### 2. 命令行版（agy）

**推荐方式（免装 MinGW，自带 `csc.exe` 编译并广播 `WM_SETTINGCHANGE`，共享 `proxy.conf`）：**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-cli-shim.ps1 -AddToPath
```

> 若新机尚未跑过桌面版脚本，只要保证 `%USERPROFILE%\.agy-shim\proxy.conf` 已写入你的代理地址（或由 `build-desktop-launcher.ps1` 自动生成），`agy` CLI 与桌面版会自动共享同一份配置；随时可用 `.\scripts\agy-proxy-toggle.ps1` 停用、恢复或查看状态。

**传统方式（MinGW-w64 原生 C）：**

```powershell
# 需要 MinGW-w64
New-Item -ItemType Directory -Force -Path "$env:LOCALAPPDATA\agy\shim"
gcc -O2 -s -Wall -o "$env:LOCALAPPDATA\agy\shim\agy.exe" src\agy-shim.c -lws2_32 -lshell32

# 加入 PATH 最前
$shimDir = '%LOCALAPPDATA%\agy\shim'
$key = Get-Item 'HKCU:\Environment'
$raw = $key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$parts = $raw -split ';' | Where-Object { $_.Trim() -ne '' }
[Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\Environment','Path',
    ((@($shimDir) + $parts) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
```

### 3. 验证、诊断与一键卸载（Windows）

```powershell
# 全面验证启动器、快捷方式、自愈脚本、proxy.conf 端口延迟、全局环境变量与 CLI shim
powershell -ExecutionPolicy Bypass -File .\scripts\verify-review.ps1

# 一键诊断 Clash 模式/策略组与 Google/Antigravity 逐域名 TLS 连通性
powershell -ExecutionPolicy Bypass -File .\scripts\diagnose-mode.ps1

# 一键卸载（支持 -DryRun 预览，默认保留 proxy.conf，传 -Purge 彻底清理）
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-windows.ps1 -DryRun

# 命令行验证（重开终端后）
(Get-Command agy).Source        # 应指向 ...\agy\shim\agy.exe
agy --version                   # 应输出 agy-shim 2.1.0 (cs)
agy -p "reply OK"               # 应返回 OK
[Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')   # 应为空
```

---

## 快速开始（Ubuntu / Linux）

Linux 下无需编译，CLI 与桌面版共用统一 multi-call Bash wrapper（[linux/proxy-wrapper.sh](linux/proxy-wrapper.sh)），通过 `exec` 透传 TTY/信号/参数/退出码。同时适配官方 `.tar.gz` 解压即用（`./Antigravity` / `./antigravity`）与官方 CLI（`~/.local/bin/agy`）：

- **绝不覆盖官方 `~/.local/bin/agy`**：官方 `install.sh` 会把真正的 CLI 安装到 `~/.local/bin/agy`。本工具将代理 shim 安装到独立目录 `~/.local/share/agy-proxy/bin/agy`，只需在 `PATH` 中排在 `~/.local/bin` 前面即可。
- **自动适配 `Antigravity.tar.gz` 与 `.desktop`**：无论解压在 `~/Downloads/Antigravity`、`~/Antigravity-x64` 还是其他目录，传 `--app-bin <解压目录或可执行文件>` 即可记录到 `~/.config/agy-proxy/app-bin.conf` 并自动生成 `~/.local/share/applications/antigravity.desktop`；若系统已有 `.desktop` 则创建用户级覆盖（升级软件不会被重置）。
- **GNOME 桌面环境兼容**：Ubuntu GNOME 下 Chromium 会优先读取 `gsettings` 系统代理并忽略环境变量 `HTTPS_PROXY`。桌面包装器检测到可用代理时会自动附加 `--proxy-server` 与 `--proxy-bypass-list=localhost;127.0.0.1;[::1]`（如需关闭该行为，设 `ANTIGRAVITY_NO_ELECTRON_PROXY_FLAG=1`）。

### 1. 安装（以 `Antigravity.tar.gz` 为例）

```bash
# 假设已解压官方压缩包：tar -xzf Antigravity.tar.gz（例如得到 ~/Antigravity-x64）
# 如尚未安装官方 CLI，可先执行：curl -fsSL https://antigravity.google/cli/install.sh | bash
chmod +x linux/*.sh

# 一键安装包装器并写入你的代理地址 + 解压目录（目录名 Antigravity / Antigravity-x64 等均可）
# --with-debug-port 会为 .desktop 补齐 Antigrative Dashboard / antigravity-pulse 调试端口（已安装该插件时可自动识别）
./linux/install-linux.sh --proxy http://127.0.0.1:<你的代理端口> --app-bin ~/Antigravity-x64 --with-debug-port
```

### 2. 持久化 `PATH`（让终端 `agy` 走代理 shim）

将独立 shim 目录写入 shell 启动文件末尾，确保排在 `~/.local/bin` 之前：

```bash
# Bash（Ubuntu 默认）
echo 'export PATH="$HOME/.local/share/agy-proxy/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 如果你使用 Zsh，请改为：
# echo 'export PATH="$HOME/.local/share/agy-proxy/bin:$PATH"' >> ~/.zshrc
# source ~/.zshrc
```

> 若终端提示 `antigravity-proxy: command not found`，再确保 `~/.local/bin` 也在 `PATH` 中（桌面应用图标不依赖终端 `PATH`，安装完即可直接点击）：
> `export PATH="$HOME/.local/share/agy-proxy/bin:$HOME/.local/bin:$PATH"`

### 3. 验证与启动

```bash
which agy                               # 应输出 ~/.local/share/agy-proxy/bin/agy
agy --shim-version                      # 应输出 agy-shim-linux 2.2.0
./linux/install-linux.sh --status       # 确认配置、.desktop 与代理端口探活状态（自定义端口会显示 [from proxy.conf]）
agy -p "reply OK"                       # 验证 CLI 走代理连通
antigravity-proxy                       # 或从桌面应用菜单启动 Antigravity GUI（无配置时也会兜底探测当前目录 ./Antigravity）
```

### 4. 改端口、换目录、沙箱排障与卸载

- **更改代理端口**：重跑 `./linux/install-linux.sh --proxy <新端口或URL>`，或直接编辑 `~/.config/agy-proxy/proxy.conf` 立即生效。
- **更换解压目录**：重跑 `./linux/install-linux.sh --app-bin <新目录或可执行文件>`（或编辑 `~/.config/agy-proxy/app-bin.conf`）。
- **Ubuntu 24.04+ `chrome-sandbox` 报错**（部分内核限制非特权用户命名空间）：可在首次验证时运行 `antigravity-proxy --no-sandbox`，或为解压目录内的 `chrome-sandbox` 授权：
  ```bash
  sudo chown root:root ~/Antigravity-x64/chrome-sandbox
  sudo chmod 4755 ~/Antigravity-x64/chrome-sandbox
  ```
- **跨平台诊断与一键卸载**（保留 `proxy.conf`，绝不删除官方 `~/.local/bin/agy`）：
  ```bash
  python3 scripts/diagnose-mode.py
  ./linux/install-linux.sh --uninstall
  ```

---

## 常见问题排查（FAQ）

| 现象 | 常见原因 | 处理方式 |
|---|---|---|
| `--status` 显示我的端口是 `open`，下面还有 `7890` `closed` | `7897 / 7890 / 10809` 仅作为**回退兜底**列出 | 只要看到 `<你的端口> open [from proxy.conf]` 即已生效，实际启动只使用你的配置端口 |
| Windows `agy` 仍报 `oauth2.googleapis.com` 超时 | 当前终端是在安装 shim 之前打开的，或被其他 `agy.exe` 抢先匹配 | 重开终端运行 `(Get-Command agy).Source` 与 `agy --version`，确认指向 `shim\agy.exe` |
| Ubuntu 运行 `agy` 未走代理 | `~/.local/share/agy-proxy/bin` 没排在 `~/.local/bin` 前 | 按上文加入 `~/.bashrc`/`~/.zshrc` 并 `source`，确认 `which agy` 指向 `.local/share/agy-proxy/bin/agy` |
| 代理明明开着，依然连接超时（或规则模式行/全局不行） | 节点本身不通 `cloudcode-pa`（半死节点）或全局模式选了 `DIRECT`/失效节点 | 运行 `scripts/diagnose-mode.ps1`（Windows）或 `python3 scripts/diagnose-mode.py`（全平台）逐域名排查并切换节点 |
| Dashboard 内嵌栏不见了 / 开始菜单被还原 | Electron Toast 通知或客户端更新重置了快捷方式 | 重跑 `repoint-shortcut.ps1 -AddDebugPort -ProtectStartMenu`；并部署开机自愈 VBS |
| 想换代理软件/换端口 | — | 修改 `proxy.conf` 第一行或重跑安装/编译脚本带新端口即可，无需改代码 |
| 想完全还原系统默认状态 | — | Windows 跑 `scripts\uninstall-windows.ps1`（加 `-Purge` 清配置）；Linux 跑 `./linux/install-linux.sh --uninstall` |

---

## 文档

| 文档 | 内容 | 适合谁 |
|---|---|---|
| [01 · 技术原理](docs/01-technical-go-proxy.md) | 为什么 Go 程序读不到系统代理；如何从日志定位 | 遇到同类问题的开发者 |
| [02 · 实践方案](docs/02-practice-per-app-proxy.md) | 三种方案对比、完整实现、代理模式选择 | 想自己配置的人 |
| [03 · 使用指南](docs/03-usage-guide.md) | 从安装到排查的完整手册（含 CLI 命令详解） | Antigravity 用户 |
| [AI 协作记录](docs/ai-collaboration/) | 自评 → 同行复核 → 修复的完整闭环 | 研究 AI 工作流的人 |
| [交接报告](docs/HANDOVER.md) | 架构、决策理由、故障树、遗留问题 | **接手维护的人 / AI** |

---

## 仓库结构

```
.
├── .github/workflows/ci.yml           # CI：ASCII / LF / PS / Bash / Linux 冒烟 / csc.exe 编译
├── .gitattributes                     # 锁定 .sh / .py / .yml 为 LF，.ps1 / .cs / .vbs 为 CRLF
├── README.md                          # 本文件
├── LICENSE                            # MIT
├── docs/
│   ├── 01-technical-go-proxy.md       # 技术原理与排查方法
│   ├── 02-practice-per-app-proxy.md   # 方案对比与完整实现
│   ├── 03-usage-guide.md              # 国内使用完全指南
│   └── ai-collaboration/
│       ├── 01-self-assessment.md      # AI 自评报告（主动列 4 项弱点）
│       ├── 02-peer-review.md          # 第一轮独立复核（发现 2 项未披露问题）
│       ├── 03-response.md             # 第一次回应、修复、方法论复盘
│       ├── 04-review-round2.md        # 第二轮复核（发现验证时效性盲区）
│       └── 05-response-round2.md      # 第二次回应（版本自证 + 症状对照）
├── src/
│   ├── ProxyCommon.cs                 # Windows 共享代理探活 / proxy.conf / 命令行截取模块
│   ├── AntigravityProxy.cs            # Windows 桌面版无窗口启动器（自带 csc.exe 编译，透传参数）
│   ├── AgyShim.cs                     # Windows CLI 转发器（自带 csc.exe 免 MinGW 编译）
│   ├── agy-shim.c                     # CLI 转发器源码（C，v2.0.0 带版本自证）
│   └── Antigravity-Proxy.cmd          # 桌面版启动器（批处理回退方案，支持 %* 参数透传）
├── linux/
│   ├── proxy-wrapper.sh               # Ubuntu/Linux 统一 multi-call wrapper（agy & antigravity-proxy）
│   └── install-linux.sh               # Ubuntu/Linux 一键安装 / 状态 / 卸载脚本
└── scripts/
    ├── build-desktop-launcher.ps1     # 编译 AntigravityProxy.exe 并管理 proxy.conf
    ├── build-cli-shim.ps1             # 编译 AgyShim.cs 为 agy.exe 并广播 WM_SETTINGCHANGE
    ├── repoint-shortcut.ps1           # 改写快捷方式指向启动器（保留原有参数，支持 -AddDebugPort / -ProtectStartMenu）
    ├── self-heal-shortcuts.ps1        # 更新/通知后自动修复（只在被还原时动手，保留参数与 AUMID）
    ├── self-heal-shortcuts.vbs        # 启动项包装（无窗口）
    ├── agy-proxy-toggle.ps1           # agy shim 启用/撤销/查状态
    ├── query-mihomo.py                # 查询 Clash 实际模式与节点（Windows 命名管道 / Linux Unix socket & HTTP）
    ├── diagnose-mode.ps1              # Windows 一键模式/节点/逐域名 TLS 诊断
    ├── diagnose-mode.py               # 跨平台一键模式/节点/逐域名 TLS 诊断（Windows + Linux）
    ├── verify-review.ps1              # 全面验证脚本
    ├── uninstall-windows.ps1          # Windows 一键卸载脚本（支持 -DryRun / -Purge）
    └── sysproxy-toggle.ps1            # 系统代理开关（测试用）
```

> **所有 `.ps1` / `.cmd` 都是纯 ASCII（全英文）。** 含中文但无 UTF-8 BOM 的 `.ps1` 在中文 Windows + PowerShell 5.1 下会被按 GBK 解析，报 `TerminatorExpectedAtEndOfString`。全英文方案不依赖任何代码页设置。

---

## 关键设计点

### agy 转发器（`src/agy-shim.c`）

放在 `PATH` 最前，拦在真实 `agy.exe` 之前：

1. **尊重已有配置**：环境里已有 `HTTPS_PROXY` / `HTTP_PROXY` 就直接放行，不覆盖
2. **探测失败不注入**：代理没开时保持原生行为，避免"修得更坏"
3. **退出码精确透传**：`WaitForSingleObject` + `GetExitCodeProcess`
4. **参数原样透传**：从 `GetCommandLineW` 提取原始参数串，避免二次解析破坏引号
5. **版本自证**：`agy --version` 可查，用于确认部署的二进制与源码一致

```powershell
> agy --version
agy-shim 2.0.0 (built Nov  8 2026)
```

> **为什么需要版本标记**：GCC 会合并字符串池，用 `strings` 搜 `HTTP_PROXY` 之类的字面量在优化后可能搜不到——新旧版本都数出 1 次，无法区分。所以放一个独立的版本串。

### 为什么 CLI 用 C 而 GUI 用 .cmd

| 程序 | 方式 | 原因 |
|---|---|---|
| CLI | 原生 exe | 交互式 TUI；可能被脚本 `subprocess` 调用；需精确透传退出码和 stdio |
| GUI | `.cmd` | 双击启动，无 stdio 顾虑；便于用户自行修改，无需编译环境 |

---

## 踩过的坑

### `NO_PROXY` 不能漏

漏了它，应用自己的本地页面会走代理，同样超时：

```
本地服务 127.0.0.1:18080
  direct    → 200
  via proxy → 502
```

### 注册表 PATH 的类型陷阱

```powershell
# ❌ GetValue() 默认展开 %LOCALAPPDATA%，写回变成硬编码路径
$raw = $key.GetValue('Path')

# ❌ Set-ItemProperty 写入类型是 String，丢失 ExpandString
Set-ItemProperty ... -Value $new

# ✅ 正确
$raw = $key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
[Microsoft.Win32.Registry]::SetValue(..., [Microsoft.Win32.RegistryValueKind]::ExpandString)
```

### 快捷方式必须逐一验证

批量修改多处时，很容易只确认手边那一个。**实测遇到过「桌面改好了、开始菜单被更新器还原」**——从桌面启动正常，从开始菜单启动原故障完整复发，极难排查。

### 采样验证前先验证采样器

做"流量是否全走代理"的验证时，踩了两个坑：

- `netstat -ano` 单次耗时 46–53ms，400ms 轮询会漏掉短连接
- `Get-NetTCPConnection` 会返回 `Bound`/`Listen` 状态，不过滤会误判为"直连外网"

---

## 验证结果（实测）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `dial tcp ... i/o timeout` | 存在 | **0 次** |
| `ERR_TIMED_OUT` | 存在 | **0 次** |
| 本地页面 HTTPS | 超时 | **HTTP 200 / 24ms** |
| `SCOPE_INSUFFICIENT`（403） | 1 次 | **0 次**（重登后） |
| 全局代理变量 | — | **全部为空（未污染）** |
| Established 连接 | — | **59/59 走代理，外部直连 0** |

---

## 环境

| 项目 | 版本 |
|---|---|
| OS | Windows 11 (10.0.26200) |
| Antigravity | 2.29.1 (Electron 44.5.1) |
| Antigravity CLI | 1.5.3 |
| 代理客户端 | Clash Verge Rev / mihomo v1.19.33 |
| 编译器 | MinGW-w64 (GCC 8.1.0) |

---

## 关于 AI 协作记录

`docs/ai-collaboration/` 记录了一次完整的 **自评 → 独立复核 → 修复** 闭环：

```
01 自评     AI 主动列 4 项弱点
    ↓ 另一个 AI 逐项实测复核
02 复核     发现 2 项自评未披露的真实问题
    ↓
03 回应     承认、修复、复盘方法论缺陷
```

复核发现的两个问题：

1. **开始菜单快捷方式未指向启动器** —— 会导致从该入口启动时原故障完整复发
2. **shim 只检查 `HTTPS_PROXY`，不检查 `HTTP_PROXY`** —— 代码与注释不一致

三个可复用的方法论教训：

- **「改了」≠「改对了」**：批量修改多处时，必须一次性断言全部目标
- **注释与实现不一致，编译器不报错**：注释应只写实现真正做的事
- **「自评说没有遗漏」是最不可信的声明**

---

## License

MIT
