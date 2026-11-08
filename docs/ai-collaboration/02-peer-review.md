# 技术评审报告：Antigravity / agy CLI 代理修复工作（复核 03-技术评估报告.md）

> **评审对象**：`Antigravity-代理问题\03-技术评估报告.md`（自评报告）
> **评审方式**：不只审报告文本——对报告声称的每一项可验证声明，在本机做了独立实测复核（注册表、环境变量、日志、快捷方式、shim 源码逐行审读、mihomo API 查询）
> **评审时间**：2026-11-08
> **总体结论**：**修复工作成立，达到可交付标准。** 报告诚实度异常高，自曝局限全部属实且无低估；但独立复核发现 **2 个报告未披露的真实漏洞**（开始菜单快捷方式未改、shim 与声明行为不符），均为 10 分钟内可修的执行遗漏/代码小偏差，不影响工作成立。

---

## 一、复核证实的声明（逐项实测）

| 报告声明 | 实测结果 |
|---|---|
| shim 在 PATH 最前 | ✅ 用户级 Path 第一项为 `%LOCALAPPDATA%\agy\shim` |
| 注册表 Path 类型保持 ExpandString | ✅ `GetValueKind('Path')` = ExpandString，`%LOCALAPPDATA%` 字面量保留 |
| 全局环境零污染 | ✅ HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY / AGY_PROXY / ANTIGRAVITY_PROXY 六个变量 user 级、machine 级**全部未设置** |
| 日志零残留 | ✅ `language_server.log` 中 `dial tcp` 0 条；`main.log` 中 `ERR_TIMED_OUT` 0 条（log 修改时间 15:15，晚于修复时刻，验证窗口有效） |
| Clash 已切 rule 模式并保持 | ✅ 用报告第 11 节自带脚本 `query-mihomo.py /configs` 查得：`mode = rule, mixed-port = 7897, tun.enable = False` |
| 系统代理恢复（ProxyEnable=1） | ✅ 实测 `ProxyEnable: 1, ProxyServer: 127.0.0.1:7897`，mihomo 正在监听 |
| 桌面快捷方式改写成功 | ✅ `Desktop\Agent\Antigravity.lnk` → `C:\Users\<you>\.agy-shim\Antigravity-Proxy.cmd`，WindowStyle=7 |
| 快捷方式原值有备份 | ✅ `shortcut-backup\desktop.txt` / `startmenu.txt` 记录了原 Target/Args/WorkDir/Icon |
| 4.3 节注册表写入的技术坑 | ✅ 是真实存在的坑（GetValue 默认展开 + Set-ItemProperty 丢类型），处理方式正确 |

**shim 源码（agy-shim.c，190 行）逐行审读结论**：

- `CreateProcessW` + `WaitForSingleObject` + `GetExitCodeProcess` 退出码透传 ✅
- `GetCommandLineW` 剥离首段后拼接，参数原样透传 ✅
- 探测失败不注入（降级安全）✅
- `NO_PROXY=localhost,127.0.0.1,::1` 注入 ✅
- IPv4 候选下 `port_of` 的 wcstoul 解析无问题；`socks5://` 经 AGY_PROXY 注入是 Go 原生支持的特性而非 bug
- 边界截断保护（`probe[MAX_PATH-1]=0`）到位 ✅

**启动器 Antigravity-Proxy.cmd（47 行）审读结论**：

- `NO_PROXY` 大小写双份设置 ✅
- 端口探测只警告不阻塞启动（`never block startup`）✅
- `setlocal/endlocal` 保证环境变量不泄漏到外层 shell ✅

---

## 二、🔴 报告未披露的漏洞（本次复核新发现）

### 1. 开始菜单快捷方式没改——从那里启动会完整复发原故障

**证据**：

- `repoint-shortcut.ps1` 的 `$targets` 数组包含**桌面 + 开始菜单**两处；
- `shortcut-backup` 也备份了两处（说明当初计划都改）；
- 但实测开始菜单 `Antigravity.lnk` **仍直指 `Antigravity.exe`**，未指向启动器。

**后果**：用户从开始菜单启动 → language_server 拿不到环境变量 → 直连 Google 超时 → 卡加载页，原症状完整复发。且用户很难想到"桌面图标正常、开始菜单图标卡死"的原因是两个入口指向不同——这正好落进报告 2.5 节自己承认的"最具误导性的坑"。

报告 8.3 说"自动更新可能重置快捷方式，有补救脚本随时可重做"——但补救脚本此刻就该跑而没跑完，第一项漏了。

**修法**：运行一次 `repoint-shortcut.ps1`（脚本本身正确，30 秒完成）。

### 2. shim 行为与自身注释/报告描述不符：只尊重 HTTPS_PROXY，不尊重 HTTP_PROXY

**证据**：

- 源码 56–58 行：只检查 `HTTPS_PROXY` / `https_proxy` 是否已设置；
- 但文件头注释（第 5 行）写的是"HTTP_PROXY / HTTPS_PROXY（用户自己设了），原样放行"；
- 报告 4.1 同样声称"若环境已有 HTTPS_PROXY → 原样放行（尊重用户已有配置）"。

**后果**：若用户只设置了 `HTTP_PROXY`（部分工具链的惯例），shim 探测到本地端口后会**覆盖它**，破坏用户已有配置。边界情况，但报告明确声称了相反的行为。

**修法**：在 56 行的判断中补一个 `GetEnvironmentVariableW(L"HTTP_PROXY", NULL, 0)` / 小写检查，重新编译 18 KB 的 shim。

---

## 三、🟡 已披露问题的确认与补充

### 3. 403 scope 错误至今每分钟在刷（报告 8.1）

实测 `language_server.log` 中 `AICode FetchConfig failed ... ACCESS_TOKEN_SCOPE_INSUFFICIENT` 在 15:13、15:14 仍在**逐分钟重复出现**（每 60 秒重试一次）。

- 报告表述"AI Code 等高级功能**可能**失败"——实测确认：**AI Code 已经在失败，且无限重试持续刷日志**；
- 需要用户交互式重新登录才能解决（报告不越权碰凭据的决策正确）；
- 建议向用户强调优先级：这是当前影响功能的主要遗留项。

### 4. 5.4 节"零直连"的诚实表述值得肯定

采样 15–24 秒确实不足以证明（报告已自知）。**补强建议**（回答报告第 10 节问题 3）：

最经济的不是 Wireshark，而是——在 agy **实际执行一次完整对话**的 30–60 秒窗口内，用 `Get-NetTCPConnection` 循环采样并按进程树 PID 过滤，事后比对全部远端地址。成本接近零，且窗口覆盖真实业务流量而非空转采样。若要进一步硬化，再上 ETW（`netsh trace`）做一次全量抓包即可收口。

---

## 四、对报告第 10 节 5 个提问的简答

| # | 报告提问 | 评审意见 |
|---|---|---|
| 1 | 2.5 因果链（Go 未就绪 → 本地页面超时）是否成立 | **成立但有一环薄弱**：H4 说"本地端口 TCP 可连"，因果链说"拿不到完整响应"。两者可共存（TCP accept 后 HTTP 层不服务），但报告缺 HTTP 层证据。建议补：修复前对 `127.0.0.1:PORT` 跑 `curl -v` 留存 HTTP 层超时证据 |
| 2 | 方案 B（进程注入）vs 方案 C（TUN）取舍 | **合理**。反作弊兼容风险是真实存在的否决理由，且方案 B 已实测有效，不属于过度谨慎 |
| 3 | 采样方法是否足以支撑"流量全走代理" | **不足以**（报告已自知）。按第三节第 4 点补强即可 |
| 4 | 是否遗漏风险点 | **有**：即第二节 #1、#2 两项。另有两点小项：① shim 目录位于用户级可写路径，恶意替换即可持久劫持 agy 执行入口（信任级别与原 bin 相同，风险低但值得知晓）；② 启动器每次启动拉一个 PowerShell 探测端口，增加约 200–500ms 启动延迟（可忽略） |
| 5 | 文档一（博客版）是否含误导内容 | **无法评审**——本次评审未提供该文件。若需评审请补充该文件 |

---

## 五、修复清单（按优先级）

| # | 事项 | 动作 | 耗时 |
|---|---|---|---|
| 1 | 开始菜单快捷方式未指向启动器 | 运行 `repoint-shortcut.ps1`（脚本已存在且正确） | 30 秒 |
| 2 | shim 不尊重 HTTP_PROXY | 补 56 行判断，重编译 shim | ~10 分钟 |
| 3 | 403 scope（AI Code 已确认失败） | 用户在 Antigravity 客户端交互式重新登录 | 用户操作 |
| 4 | "零直连"验证补强 | agy 真实对话期间跑 `Get-NetTCPConnection` 采样 | 5 分钟 |
| 5 | （可选）HTTP 层因果链证据 | 保留一份修复前 `curl -v https://127.0.0.1:PORT` 输出 | 1 分钟 |

---

## 六、评审结论

> **修复有效，根因判断（Go 运行时不读 Windows 系统代理、只读环境变量）证据链充分且与本机实测吻合。方案选型合理，全部系统变更可逆且有备份，全局环境未被污染（六变量实测全空）。**
>
> **本次复核新发现 2 项报告未披露的问题**：① 开始菜单快捷方式漏改（会导致从该入口启动时原故障完整复发）；② shim 源码行为与注释/报告声明不符（不尊重 HTTP_PROXY）。
>
> **两项均为 10 分钟内可修完的执行遗漏/代码小偏差，不改变"工作成立、可交付"的结论。** 唯一需要用户行动的实质遗留是 403 scope 重新登录——实测确认 AI Code 功能当前正在每分钟失败重试。

---

## 附录：复核所用的实测命令（供第三方再复核）

```powershell
# 1. shim 生效与类型
(Get-Command agy).Source                          # 期望 ...\agy\shim\agy.exe
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
$key.GetValueKind('Path')                         # 期望 ExpandString

# 2. 全局环境零污染
[Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')   # 期望：空

# 3. 日志零残留
Select-String "$env:APPDATA\Antigravity\logs\language_server.log" -Pattern "dial tcp"
Select-String "$env:APPDATA\Antigravity\logs\main.log" -Pattern "ERR_TIMED_OUT"

# 4. Clash 当前模式（报告自带脚本）
python $env:USERPROFILE\.agy-shim\query-mihomo.py /configs

# 5. 快捷方式状态（本次新发现 #1 的复现命令）
$sh = New-Object -ComObject WScript.Shell
$sh.CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Antigravity.lnk").TargetPath
# 实测：仍指向 Antigravity.exe（未指向启动器）→ 复发风险

# 6. 403 现状（第三节 #3 的复现命令）
Select-String "$env:APPDATA\Antigravity\logs\language_server.log" -Pattern "SCOPE_INSUFFICIENT" | Measure-Object
```

---

*评审报告结束。基于报告文本审读 + 本机 PowerShell 实测复核（注册表 / 环境变量 / 日志 / COM 快捷方式 / mihomo API / C 源码逐行审读）。*
