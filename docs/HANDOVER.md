# 交接报告：Antigravity / agy 代理方案

> **交接时间**：2026-11-14
> **接手指南**：先读本文件，再按需查阅 `docs/` 下的详细文档
> **仓库**：https://github.com/xiaobaijiadepugongyingpai-coder/antigravity-proxy-fix

---

## 0. 三十秒速览

| 项 | 状态 |
|---|---|
| 核心问题 | ✅ 已解决（Go 程序不读 Windows 系统代理） |
| 本机部署 | ✅ 已完成并验证 |
| 仓库代码 | ✅ 已同步（HEAD `350987e`） |
| 自愈机制 | ✅ 已装到启动项（本次交接新装） |
| 已知遗留 | ⚠️ 3 项（见第 7 节） |
| 待验证 | ⚠️ 另一台机器的模式差异（见第 8 节） |

**一句话**：方案本身成熟可用，剩下的都是**环境性、非代码性**的问题。

---

## 1. 问题本质（最重要的一页）

### 1.1 根因

**Go 编译的程序只读环境变量 `HTTP_PROXY` / `HTTPS_PROXY`，完全不读 Windows 系统代理（注册表 IE 设置 / WinHTTP / PAC）。**

Antigravity 是双进程：

```
Antigravity.exe          ← Electron 外壳，认系统代理 ✅
    └─ language_server.exe   ← Go 内核，只认环境变量
```

只开系统代理时，外壳正常、内核直连 → 超时 → 界面卡死。

### 1.2 一个极具误导性的症状

```
electron: Failed to load URL: https://127.0.0.1:12111/ with error: ERR_TIMED_OUT
```

**报错指向本地地址，但根因在远端。** 真正的答案在同目录的 `language_server.log`：

```
dial tcp 172.217.115.4:443: i/o timeout
```

`dial tcp ... i/o timeout` 是 Go 运行时的特征报错。**看到它就知道：这进程是 Go 写的，它在直连。**

### 1.3 为什么不用全局环境变量

实测过，副作用太大：

```
本地服务 127.0.0.1:18080
  direct    → 200
  via proxy → 502      ← 本机服务全挂
```

而且代理一关就全系统断网。所以采用**进程级注入**。

---

## 2. 方案架构

```
┌─────────────────────────────────────────────────┐
│  Windows 环境（干净，无全局代理变量）             │
│                                                   │
│  其它程序 ──────直连──────> 不受影响              │
│                                                   │
│  agy ──────shim 注入─────┐                       │
│  Antigravity ──cmd 注入──┤                       │
│                          ▼                       │
│                  127.0.0.1:7897 (Clash)          │
└─────────────────────────────────────────────────┘
```

### 2.1 agy：C 编译的原生转发器

```
%LOCALAPPDATA%\agy\
  ├─ shim\agy.exe      ← 转发器（PATH 最前），v2.0.0
  ├─ shim\agy-v0.9.0-backup.exe.disabled
  ├─ shim\agy-v1.0.0-backup.exe.disabled
  └─ bin\agy.exe       ← 原始程序，未改动
```

**为什么用 C 不用 .cmd**：agy 是交互式 TUI，可能被 `subprocess` 调用，需要精确透传退出码和 stdio。`.cmd` 中间层会丢退出码、TUI 会花屏。

**转发器行为**（`src/agy-shim.c`）：

1. 环境已有 `HTTPS_PROXY` / `HTTP_PROXY`（四个大小写变体任一）→ **原样放行，不覆盖**
2. 否则按序探测：`AGY_PROXY` → `7897` → `7890`
3. **全部探测失败则不注入**（代理关闭时保持原生行为，避免"修得更坏"）
4. 参数原样透传，退出码原样返回
5. `--version` 自证版本（v2.0.0 新增）

### 2.2 Antigravity：.cmd 启动器 + 改快捷方式

```cmd
set "HTTPS_PROXY=http://127.0.0.1:7897"
set "HTTP_PROXY=http://127.0.0.1:7897"
set "NO_PROXY=localhost,127.0.0.1,::1"    ← 这行不能漏
start "" "%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe"
```

**`NO_PROXY` 是关键**。不设它，应用自己的本地页面也会走代理，一样白屏。

### 2.3 为什么 CLI 用 C 而 GUI 用 .cmd

| 程序 | 方式 | 原因 |
|---|---|---|
| CLI | 原生 exe | 交互式 TUI；可能被脚本调用；需精确 stdio/退出码 |
| GUI | `.cmd` | 双击启动无顾虑；用户可自行修改，无需编译环境 |

**这个不对称是有意的，不是随意选择。**

---

## 3. 本机部署清单（已完成）

### 3.1 系统变更（全部可逆）

| 位置 | 变更 | 备份 |
|---|---|---|
| `HKCU\Environment\Path` | 最前插入 `%LOCALAPPDATA%\agy\shim` | 值类型保持 `ExpandString` |
| 桌面 `Desktop\Agent\Antigravity.lnk` | 目标 → 启动器 | `~/.agy-shim/shortcut-backup/` |
| 开始菜单 `Antigravity.lnk` | 目标 → 启动器 | 同上 |
| 启动项 `antigravity-self-heal.vbs` | 新增（本次交接装） | — |
| PowerShell 执行策略 | `Restricted` → `RemoteSigned` | 一条命令回退 |

**全局代理变量：全部未设置（已反复验证）。**

### 3.2 文件清单

**仓库内**（已同步 GitHub）：

```
antigravity-proxy-fix/
├── README.md
├── LICENSE
├── docs/
│   ├── 01-technical-go-proxy.md       技术原理
│   ├── 02-practice-per-app-proxy.md   方案对比与实现
│   ├── 03-usage-guide.md              使用指南（最全，1232 行）
│   └── ai-collaboration/              评审闭环记录（5 份）
├── src/
│   ├── agy-shim.c                     CLI 转发器（v2.0.0）
│   └── Antigravity-Proxy.cmd          桌面版启动器
└── scripts/
    ├── repoint-shortcut.ps1           全量重写快捷方式
    ├── self-heal-shortcuts.ps1        自愈（幂等）
    ├── self-heal-shortcuts.vbs        启动项包装
    ├── agy-proxy-toggle.ps1           启用/撤销/查状态
    ├── query-mihomo.py                查 Clash 状态
    ├── verify-review.ps1              全面验证
    └── sysproxy-toggle.ps1            系统代理开关（测试用）
```

**本机额外部署**（不在仓库）：

```
%LOCALAPPDATA%\agy\shim\agy.exe              转发器 v2.0.0
%USERPROFILE%\.agy-shim\                     工作目录
  ├─ agy-shim.c                              源码副本
  ├─ Antigravity-Proxy.cmd
  ├─ self-heal-shortcuts.ps1
  ├─ shortcut-backup\                        快捷方式原始值
  ├─ logs-backup\                            修复前日志
  └─ verify-binary.ps1                       二进制验证（本机专用）
```

---

## 4. 常用操作手册

### 4.1 查状态

```powershell
# agy 版本自证（最重要的一行）
agy --version
# 期望：agy-shim 2.0.0 (built ...)

# Clash 模式与节点
python "<仓库>\scripts\query-mihomo.py" proxies

# 全面验证
powershell -ExecutionPolicy Bypass -File "<仓库>\scripts\verify-review.ps1"
```

### 4.2 修复快捷方式

```powershell
# 自愈（只在被还原时动手，推荐）
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agy-shim\self-heal-shortcuts.ps1"

# 全量重写（首次配置或彻底重置）
powershell -ExecutionPolicy Bypass -File "<仓库>\scripts\repoint-shortcut.ps1"
```

### 4.3 重新编译 shim

```powershell
# 需要 MinGW-w64
gcc -O2 -s -Wall -o "$env:LOCALAPPDATA\agy\shim\agy.exe" `
    "<仓库>\src\agy-shim.c" -lws2_32 -lshell32
```

**注意 `-lshell32`** —— v2.0.0 用了 `CommandLineToArgvW`。

### 4.4 完全撤销

```powershell
# agy
powershell -ExecutionPolicy Bypass -File "<仓库>\scripts\agy-proxy-toggle.ps1"
# 选 2

# Antigravity
# 把快捷方式改回：%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe

# 自愈脚本
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\antigravity-self-heal.vbs"

# PowerShell 策略
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Restricted
```

---

## 5. 故障诊断决策树

### 5.1 agy 不可用

```
第 1 步：agy --version
  ├─ 有输出（agy-shim 2.0.0）→ shim 正常，进第 2 步
  └─ 无输出或报错 → shim 有问题
       ├─ (Get-Command agy).Source 指向 bin\ → PATH 问题，重跑 agy-proxy-toggle.ps1
       └─ 指向 shim\ 但仍无输出 → 重新编译

第 2 步：分域名测连通性
```

```powershell
'cloudcode-pa.googleapis.com','daily-cloudcode-pa.googleapis.com',
'oauth2.googleapis.com','accounts.google.com' | ForEach-Object {
    $code = curl.exe -x http://127.0.0.1:7897 -s -o NUL -w "%{http_code}" --max-time 10 "https://$_/"
    "{0,-40} {1}" -f $_, $code
}
```

| 结果 | 判定 | 处理 |
|---|---|---|
| 全部 404/302/204 | 正常 | 问题在别处 |
| **全部 000** | 配置失效 或 节点整体不通 | 先查 Clash 模式/节点（见 5.3），再查 shim |
| **只有 cloudcode 系 000** | **节点对 Google AI 上游故障** | **换节点，配置不用动** |

### 5.2 Antigravity 白屏

```
第 1 步：看是哪个入口启动的
  桌面图标正常、开始菜单卡死 → 典型症状：快捷方式被更新还原

第 2 步：运行 self-heal-shortcuts.ps1
  有输出 = 修好了
  无输出 = 快捷方式正常，进第 3 步

第 3 步：看日志
  %APPDATA%\Antigravity\logs\language_server.log
  搜 "dial tcp" → 有就是内核在直连（代理没生效）
```

### 5.3 Clash 状态检查

```powershell
python "<仓库>\scripts\query-mihomo.py" proxies
```

**重点看 `GLOBAL` 和默认策略组两个 Selector 指向什么节点。**

⚠️ **陷阱**：机场会把流量信息伪装成节点塞进列表：

```
[X] 剩余流量：761.52 GB        ← 假节点，连不上
[X] 距离下次重置剩余：16 天     ← 假节点
[X] 套餐到期：2027-03-29       ← 假节点
[X] DIRECT                     ← 直连，等于没开代理
[X] REJECT                     ← 拒绝所有
```

**如果 Selector 停在上面任何一个上，就是"全都不通"。**

---

## 6. 关键设计决策与理由

| 决策 | 理由 | 反例/代价 |
|---|---|---|
| 进程级注入而非全局变量 | 全局变量会让本地服务 502、代理一关全系统断网 | 需为每个程序单独配 |
| 不用 TUN | 用户机器有 LOL/WeGame，反作弊可能冲突 | 需手动管理多个程序 |
| CLI 用 C 而非 .cmd | TUI + subprocess 调用需要精确 stdio/退出码 | 用户需 MinGW 编译 |
| 探测失败不注入 | 避免"修得更坏"（代理没开时不让程序崩） | 用户可能以为是修复失效 |
| 所有 .ps1 写纯 ASCII | PS 5.1 + 中文 Windows 按 GBK 解析无 BOM 的 UTF-8 | 牺牲了中文可读性 |
| self-heal 幂等 | 正常时不写任何东西，避免每次都触发磁盘/杀软 | — |

### 6.1 关于纯 ASCII 的说明

**这是社区反馈换来的教训。** 原脚本含中文无 BOM，中文 Windows + PS 5.1 直接报：

```
ParserError: TerminatorExpectedAtEndOfString
```

社区建议加 BOM，我们选择了**全英文**：BOM 能修 PS 5.1，但会干扰 Git Bash 和部分编辑器，而且用户另存时可能又丢 BOM。

**维护时请保持这个约定：`.ps1` / `.cmd` 里不要出现中文。**

---

## 7. 已知遗留问题

### 7.1 ⚠️ 应用更新会重置快捷方式（已缓解，未根除）

**根因**：Antigravity 用 Squirrel/Electron 更新框架，每次安装都重建开始菜单快捷方式，写回原始 exe。

**这是设计行为，无法阻止。**

**当前缓解**：启动项 `antigravity-self-heal.vbs` 每次登录兜底。

**但仍有窗口期**：更新完成后、下次登录前，从开始菜单启动会失败。

**建议后续**：如果 Squirrel 支持 `--do-not-create-shortcut` 之类的参数，可以研究；或者用计划任务在进程退出时触发 self-heal。

### 7.2 ⚠️ 节点健康是动态变量

`shim` 只保证"流量走代理"，**不保证"代理能出网"**。

节点半死时（TCP 通但特定上游丢包），转发器照样注入变量，程序照样超时。

**这个边界已写进文档，但用户容易误判为修复失效。**

### 7.3 ⚠️ 全局模式 vs 规则模式的差异未完全定位

**这是当前最需要跟进的**，详见第 8 节。

---

## 8. 未完成事项：模式差异排查

### 8.1 用户报告

> 规则模式下可用，全局模式下反而不行

**但用户补充说明：问题出在「另一台机器」上，不是当前这台。**

### 8.2 本机实测结论（供参考）

| 模式 | 选择器 | 节点 | agy models |
|---|---|---|---|
| 规则 | `<proxy-group>` | 台湾家宽**2-Gemini** | 3.4–5.8 秒 |
| 全局 | `GLOBAL` | 台湾家宽**A4-Netflix** | 3.9–7.7 秒 |

**本机两种模式都能用，全局慢约 2 倍。**

慢的原因定位到 TLS 握手：

```
全局模式：cloudcode-pa.googleapis.com  tls=1.110s（其它域名 0.172s）
规则模式：cloudcode-pa.googleapis.com  tls=0.496s
```

`cloudcode-pa` 正是 agy 拉模型列表用的域名。

### 8.3 核心判断

**这不是模式的问题，是节点的问题。**

```
规则模式 → DOMAIN-KEYWORD,google → <proxy-group> → 2-Gemini（机场专为 Gemini 优化）
全局模式 → 所有流量             → GLOBAL   → A4-Netflix（为 Netflix 优化）
```

切模式 = 换节点。

节点对 `cloudcode-pa` 的延迟实测：

| 节点 | 延迟 |
|---|---|
| 2-Gemini | **59 ms** |
| A4-Netflix | **213 ms** |

### 8.4 待验证假设（另一台机器）

按可能性排序：

1. **GLOBAL 指向了假节点或 DIRECT**（最可能）
   - 机场把流量信息伪装成节点，`DIRECT` = 直连
   - 需要在对方机器上跑 `query-mihomo.py proxies` 确认

2. **对方机器上 A4-Netflix 节点已失效**
   - 本机通不代表对方通

3. **GLOBAL 指向了「自动选择」(URLTest)**
   - 会自动切节点，IP 跳变，可能切到坏节点

### 8.5 后续怎么查

在**出问题的机器**上执行：

```powershell
# 1. 看 GLOBAL 指向
python query-mihomo.py proxies

# 2. 测该节点对 cloudcode-pa
curl.exe -x http://127.0.0.1:7897 -s -o NUL `
  -w "code=%{http_code} tls=%{time_appconnect}s`n" --max-time 15 `
  https://cloudcode-pa.googleapis.com/

# 3. 逐域名对比
'cloudcode-pa.googleapis.com','oauth2.googleapis.com','www.google.com' | ForEach-Object {
    $code = curl.exe -x http://127.0.0.1:7897 -s -o NUL -w "%{http_code}" --max-time 10 "https://$_/"
    "{0,-40} {1}" -f $_, $code
}
```

**建议后续把这个做成 `diagnose-mode.ps1` 一键脚本。**

---

## 9. 维护注意事项

### 9.1 改代码时

| 改了什么 | 必须同步 |
|---|---|
| `src/agy-shim.c` | 重新编译 → 部署 → **改 `SHIM_VERSION`** → 更新文档里的源码 |
| 任何 `.ps1` | 保持纯 ASCII，不写中文 |
| 快捷方式逻辑 | 同步更新 `repoint-shortcut.ps1` 和 `self-heal-shortcuts.ps1` |
| 端口号 | 同步改 `src/Antigravity-Proxy.cmd` 和 shim 的候选端口 |

### 9.2 文档代码与实现的一致性（踩过的坑）

**曾经发生过**：代码修了 bug（补 `HTTP_PROXY` 检查），但 `docs/` 里三份文档的源码片段还是旧版。**读者照文档抄会得到有缺陷的版本。**

**现在的检查方法**：

```powershell
# 改完代码后，搜一遍文档里是否有该代码的副本
Select-String -Path docs\*.md -Pattern "HTTP_PROXY"
```

**任何代码改动，都要 grep 一遍所有文档。**

### 9.3 验证结论要带前提

**评审换来的教训**：验证通过的前提是环境健康。而环境是动态的（节点、代理开关、Clash 配置都会变）。

**所以验证结论应写成**：

> ❌ "agy 现在可以用了"
> ✅ "用这条命令测，全通就正常；只有某些域名不通就是节点问题"

**前者是快照，后者是可复用的判断力。**

### 9.4 提交前检查清单

```powershell
# 1. 纯 ASCII 检查
python -c "
import glob
for f in glob.glob('scripts/*.ps1')+glob.glob('src/*.cmd'):
    d=open(f,'rb').read()
    n=sum(1 for b in d if b>127)
    print(f, 'OK' if n==0 else f'NON-ASCII({n})')
"

# 2. 脱敏检查（个人路径/账号/IP/策略组名）
Select-String -Path docs\*.md -Pattern "19187|DESKTOP-|XX机场|61\.223|111\.246"

# 3. PS 解析测试
powershell -Command "foreach($f in Get-ChildItem scripts\*.ps1){ try{[scriptblock]::Create((Get-Content -Raw $f))|Out-Null; 'OK '+$f}catch{'FAIL '+$f} }"
```

### 9.5 脱敏清单

公开仓库前必须清理：

| 类型 | 替换为 |
|---|---|
| `C:\Users\<真实用户名>\` | `C:\Users\<you>\` |
| `<真实主机名>` | `<HOSTNAME>` |
| 真实出口 IP | `x.x.x.x` |
| 机场策略组名（如"XX机场"） | `<proxy-group>` |
| GitHub 账号名（文档里） | 保留（仓库地址是公开的） |

**注意**：每次从本机文档覆盖到仓库后，脱敏会丢失，**必须重跑**。

---

## 10. 关键数据快照（2026-11-14）

```
agy --version              → agy-shim 2.0.0 (built Nov  8 2026)
(Get-Command agy).Source   → %LOCALAPPDATA%\agy\shim\agy.exe
Clash mode                 → rule
Clash mixed-port           → 7897
<proxy-group> → 台湾家宽2-Gemini
GLOBAL   → 台湾家宽A4-Netflix
自动选择 → 台湾家宽A4-Netflix (URLTest，会跳)

出口 IP                    → （已脱敏，台湾中华电信）
两张快捷方式               → 均指向 Antigravity-Proxy.cmd ✅
启动项自愈                 → 已部署 ✅
全局代理变量               → 全部未设置 ✅
403 / SCOPE                → 0 ✅
```

---

## 11. 如果你是接手的新 AI / 新会话

### 11.1 先做的事

1. **读本文件**（你在做的）
2. **跑一遍验证**，确认当前状态与第 10 节一致：

```powershell
agy --version
python "<仓库>\scripts\query-mihomo.py" proxies
powershell -ExecutionPolicy Bypass -File "<仓库>\scripts\verify-review.ps1"
```

3. **不要盲目改代码**。这个方案经过两轮 AI 评审，改动前先看 `docs/ai-collaboration/` 理解已有决策。

### 11.2 这个项目的历史（避免重复踩坑）

| 轮次 | 发生了什么 | 教训 |
|---|---|---|
| 初版 | 方案成型、部署验证 | — |
| 第一轮评审 | 发现 2 个真实缺陷（快捷方式漏改、shim 逻辑不一致） | **"改过" ≠ "改对了"** |
| 第二轮评审 | 发现方法论盲区（验证声明有时效性） | **"通过" ≠ "稳定"** |
| 社区反馈 | PS 5.1 中文解析报错 | **跨平台编码不能想当然** |

**共同模式**：把"我观察到的一次"当成"普遍成立"。

### 11.3 待办优先级

| 优先级 | 事项 |
|---|---|
| 🔴 高 | 排查另一台机器的模式差异（见第 8 节） |
| 🟡 中 | 把诊断命令做成 `diagnose-mode.ps1` |
| 🟡 中 | 研究 Squirrel 更新能否禁止重建快捷方式 |
| 🟢 低 | 加 GitHub Actions 自动检查 ASCII |
| 🟢 低 | GitHub Releases 附编译好的 shim.exe（免装 MinGW） |

### 11.4 沟通注意

- **用户偏好中文回复**，但**代码文件必须英文**
- 用户会做 AI 交叉评审，**结论要能经得起复核**
- 用户在意"证据"，不要只给结论，要给命令和预期输出

---

## 12. 参考资源

| 内容 | 位置 |
|---|---|
| 完整使用指南 | `docs/03-usage-guide.md` |
| 技术原理 | `docs/01-technical-go-proxy.md` |
| 方案对比与实现 | `docs/02-practice-per-app-proxy.md` |
| 评审闭环记录 | `docs/ai-collaboration/`（5 份） |
| 原完整底稿 | 本地 `Antigravity-代理问题/`（未公开） |

---

*交接完毕。方案已稳定可用，剩余问题均为环境性而非代码性。*
