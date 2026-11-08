# Antigravity Proxy Fix

> 让 Google Antigravity 桌面版和 Antigravity CLI (`agy`) 在中国大陆网络环境下正常工作

[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)]()
[![Tested](https://img.shields.io/badge/tested-Antigravity%202.29.1%20%7C%20agy%201.5.3-green)]()
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

## 快速开始

### 1. 桌面版（Antigravity）

```powershell
# 下载 src/Antigravity-Proxy.cmd，放到 %USERPROFILE%\.agy-shim\
# 修改里面的端口号（默认 7897）

# 然后运行 scripts/repoint-shortcut.ps1 改写快捷方式
powershell -ExecutionPolicy Bypass -File .\scripts\repoint-shortcut.ps1
```

### 2. 命令行版（agy）

```powershell
# 需要 MinGW-w64
New-Item -ItemType Directory -Force -Path "$env:LOCALAPPDATA\agy\shim"
gcc -O2 -s -Wall -o "$env:LOCALAPPDATA\agy\shim\agy.exe" src\agy-shim.c -lws2_32

# 加入 PATH 最前
$shimDir = '%LOCALAPPDATA%\agy\shim'
$key = Get-Item 'HKCU:\Environment'
$raw = $key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$parts = $raw -split ';' | Where-Object { $_.Trim() -ne '' }
[Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\Environment','Path',
    ((@($shimDir) + $parts) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
```

### 3. 验证

```powershell
(Get-Command agy).Source        # 应指向 ...\agy\shim\agy.exe
agy -p "reply OK"               # 应返回 OK
[Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')   # 应为空
```

---

## 文档

| 文档 | 内容 | 适合谁 |
|---|---|---|
| [01 · 技术原理](docs/01-technical-go-proxy.md) | 为什么 Go 程序读不到系统代理；如何从日志定位 | 遇到同类问题的开发者 |
| [02 · 实践方案](docs/02-practice-per-app-proxy.md) | 三种方案对比、完整实现、代理模式选择 | 想自己配置的人 |
| [03 · 使用指南](docs/03-usage-guide.md) | 从安装到排查的完整手册（含 CLI 命令详解） | Antigravity 用户 |
| [AI 协作记录](docs/ai-collaboration/) | 自评 → 同行复核 → 修复的完整闭环 | 研究 AI 工作流的人 |

---

## 仓库结构

```
.
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
│   ├── agy-shim.c                     # CLI 转发器源码（C，v2.0.0 带版本自证）
│   └── Antigravity-Proxy.cmd          # 桌面版启动器
└── scripts/
    ├── repoint-shortcut.ps1           # 改写快捷方式指向启动器
    ├── agy-proxy-toggle.ps1           # agy shim 启用/撤销/查状态
    ├── query-mihomo.py                # 查询 Clash 实际模式与节点
    ├── verify-review.ps1              # 全面验证脚本
    └── sysproxy-toggle.ps1            # 系统代理开关（测试用）
```

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
