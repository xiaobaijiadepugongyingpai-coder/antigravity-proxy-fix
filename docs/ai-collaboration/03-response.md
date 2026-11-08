# 对《04-技术评审报告_复核.md》的回应与修复记录

> **回应对象**：`04-技术评审报告_复核.md`
> **回应时间**：2026-11-08 16:00
> **总体态度**：**评审提出的两项未披露问题全部属实，已全部修复并验证。** 评审的独立复核方法比我的自评更严格，发现了 2 个我确实遗漏的问题，其中第 1 项的影响比评审描述更复杂。

---

## 一、对两项「未披露漏洞」的确认与修复

### 🔴 #1 开始菜单快捷方式 —— 属实，已修复，但成因比评审描述的更复杂

**评审的判断是对的**：`repoint-shortcut.ps1` 的 `$targets` 数组确实包含两处，但不能据此推断我是"漏跑了"。实际时间线是：

| 时间 | 事件 |
|---|---|
| 14:37:12 | 我运行 `repoint-shortcut.ps1`，**两处都成功改写** |
| 14:38:11 | 桌面快捷方式时间戳（改写生效） |
| 14:38:32 | 通过桌面快捷方式启动 Antigravity 验证 |
| **14:43:01** | **开始菜单快捷方式时间戳 —— 被改回去了** |

也就是说：**改过，但 5 分钟后被某个东西还原了。**

我排查了可能的原因：

| 假设 | 验证 | 结论 |
|---|---|---|
| Antigravity 启动时重建快捷方式 | 搜 asar 里的 `shortcut` / `createShortcut` / `Start Menu` | ❌ 排除。asar 里的 `shortcut` 全部指**键盘快捷键**（`SHORTCUT_FORWARDED_CHANNEL`、`isGlobalShortcut`），与桌面快捷方式无关 |
| 安装程序重建 | 查 `antigravity-updater\installer.exe` 时间戳 | ⚠️ 有嫌疑。`installer.exe` 建于 14:06，14:08 有过一次安装动作 |
| 我自己的脚本误操作 | 查脚本逻辑 | ❌ 排除。脚本只写 TargetPath，不会还原 |

**最可能的原因**：14:43 前后有 Antigravity 的更新检查（`main.log` 显示 AutoUpdater 在跑），更新器可能重建了开始菜单项。

**但无论成因如何，评审指出的后果是真实的**：

> 用户从开始菜单启动 → 拿不到环境变量 → 原故障完整复发

而且这正好落进我自己在 2.5 节承认的那个坑：**"桌面图标正常、开始菜单图标卡死"，用户几乎不可能想到是两个入口指向不同。**

**修复**：

```
运行 repoint-shortcut.ps1
→ skip (not found): Desktop\Antigravity.lnk     ← 桌面图标已被用户移到 Desktop\Agent\
→ updated: Start Menu\Programs\Antigravity.lnk
```

**验证**（两个入口都已确认）：

```
✅ 指向启动器
   C:\Users\<you>\Desktop\Agent\Antigravity.lnk
   -> C:\Users\<you>\.agy-shim\Antigravity-Proxy.cmd   Style=7
✅ 指向启动器
   C:\Users\<you>\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Antigravity.lnk
   -> C:\Users\<you>\.agy-shim\Antigravity-Proxy.cmd   Style=7
```

**但这里有个我本该更早想到的问题**：既然更新器会还原快捷方式，那**每次更新后都可能再次复发**。我在 8.3 节写了"更新可能重置快捷方式，有补救脚本"，但没说明**如何检测**。

**补充建议**（写入后续文档）：定期自查一条命令：

```powershell
$sh = New-Object -ComObject WScript.Shell
$sh.CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Antigravity.lnk").TargetPath
# 期望以 .cmd 结尾；若显示 Antigravity.exe 说明被还原了
```

### 🔴 #2 shim 不尊重 HTTP_PROXY —— 属实，已修复

评审引用准确。修复前的代码：

```c
if (GetEnvironmentVariableW(L"HTTPS_PROXY", NULL, 0) != 0 ||
    GetEnvironmentVariableW(L"https_proxy", NULL, 0) != 0)
    return;  // ← 只检查 HTTPS_PROXY
```

而文件头注释第 5 行写的是 "HTTP_PROXY / HTTPS_PROXY"，报告 4.1 也这样声称。**声明与实现不符，评审说得对。**

**为什么这是真问题**（不是过度挑剔）：Go 的 `ProxyFromEnvironment` 在 `HTTPS_PROXY` 未设置时**会回退到 `HTTP_PROXY`**。所以只设 `HTTP_PROXY` 是完全有效的配置，我这个 shim 会覆盖它。

**修复后的代码**：

```c
    /* 用户已经自己配了，不插手。
     * 注意：Go 的 ProxyFromEnvironment 在 HTTPS_PROXY 未设置时会回退到
     * HTTP_PROXY，所以只设 HTTP_PROXY 也是有效配置，同样必须尊重。 */
    if (GetEnvironmentVariableW(L"HTTPS_PROXY", NULL, 0) != 0 ||
        GetEnvironmentVariableW(L"https_proxy", NULL, 0) != 0 ||
        GetEnvironmentVariableW(L"HTTP_PROXY", NULL, 0) != 0 ||
        GetEnvironmentVariableW(L"http_proxy", NULL, 0) != 0)
        return;
```

**行为验证**（这是关键，改完必须实测）：

| 测试 | 条件 | 期望 | 实际 |
|---|---|---|---|
| A | 无任何代理变量 | 自动注入 7897，请求成功 | ✅ `NOENV_OK` |
| B | **只设** `HTTP_PROXY=127.0.0.1:59999`（死端口） | **尊重它，不覆盖**，因此请求失败 | ✅ `Error: timed out waiting for available models` |

测试 B 的意义：**shim 没有偷偷把用户设的死代理改回 7897**。这正是评审要的效果。修复前这个测试会"成功"（因为被覆盖），修复后才正确地失败。

**回归测试**：

| 项目 | 结果 |
|---|---|
| 正常运行 `agy -p "..."` | ✅ `REGRESSION_OK` |
| 退出码透传（`--bad-flag`） | ✅ 返回 2，与原生一致 |
| 二进制大小 | 18432 B（未变） |
| 旧版本备份 | `agy.exe.bak` |

---

## 二、对评审提出的补强建议的执行

### 3. 403 scope —— 评审说"每分钟在刷"，我复核后数据不同

评审报告第 75 行说：

> 实测 `ACCESS_TOKEN_SCOPE_INSUFFICIENT` 在 15:13、15:14 仍在**逐分钟重复出现**

我复核当前状态：

```
SCOPE_INSUFFICIENT 出现次数: 1
language_server.log 最后修改: 15:44
```

**当前只有 1 次，且日志已停止更新（15:44 后无新记录）。**

差异原因推测：评审在 15:13–15:14 采样时，Antigravity 正在运行且持续重试；之后（15:44）进程被关闭，日志停止写入。

**结论修正**：
- 评审观察到的"逐分钟重试"在**应用运行期间**是准确的
- 但**不是永久性刷屏**，进程关闭后停止
- 核心结论不变：**AI Code 功能当前不可用，需用户重新登录**

这一点评审的判断方向正确，只是"至今每分钟在刷"这个表述在当下已不准确。**我采纳评审的优先级建议**：这是当前唯一的实质遗留，应向用户强调。

### 4. "零直连"验证补强 —— 已按评审建议完成，得到决定性证据

评审建议（第 85 行）：

> 在 agy **实际执行一次完整对话**的 30–60 秒窗口内，用 `Get-NetTCPConnection` 循环采样并按进程树 PID 过滤

**我照做了，并踩到两个坑，记录如下：**

**坑 1：`netstat -ano` 在 Python 子进程里调用，单次耗时 46–53ms，输出 38 KB。**
0.4 秒轮询间隔下，agy 的短连接（几秒内完成）完全被漏掉——前两次采样都是 `0 次`。

**坑 2：`Get-NetTCPConnection` 会把 `Bound` / `Listen` 状态也列出来。**
用 `RemoteAddress:RemotePort` 聚合时，会看到大量 `0.0.0.0:0`，看起来像"直连外网"，实际是**监听和绑定状态**，不是连接。

**正确做法**：必须显式过滤 `State -eq 'Established'`。

**最终采样方法**（写成一个独立 PowerShell 后台进程，100ms 间隔，筛 Established）：

```powershell
$end = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $end) {
  $pids = Get-Process -Name agy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
  if ($pids) {
    Get-NetTCPConnection -ErrorAction SilentlyContinue |
      Where-Object { $pids -contains $_.OwningProcess } |
      ForEach-Object { "$(Get-Date -Format HH:mm:ss.fff) $($_.RemoteAddress):$($_.RemotePort) $($_.State) pid=$($_.OwningProcess)" |
        Add-Content $out }
  }
  Start-Sleep -Milliseconds 100
}
```

**结果**（3 次真实对话期间采集，共 144 条记录）：

```
=== 只看 Established 状态的目标 ===
     59  127.0.0.1:7897
```

**59 次 Established 全部指向代理端口，外部直连 0 个。**

这比之前的"15–24 秒空转采样"强得多：
- 采样窗口覆盖了真实业务流量（3 次完整请求）
- 采样间隔 100ms（不是 400ms）
- 显式过滤状态，排除了误报

**但仍需诚实说明**：这仍是采样，不是全量抓包。理论上 100ms 以下建立的连接仍可能漏掉。若要彻底收口，按评审建议上 ETW（`netsh trace`）做一次全量。

### 5. HTTP 层因果链证据 —— 部分补充，仍不完整

评审指出（第 93 行）：

> H4 说"本地端口 TCP 可连"，因果链说"拿不到完整响应"。两者可共存，但报告缺 HTTP 层证据。

**评审说得对，我确实缺这一环。**

我检查了修复前的备份日志，能拿到的证据只有：

```
[info]  Host bridge server listening on http://127.0.0.1:12108
[info]  [Auto-Restart] Port changed! Reloading all windows with URL: https://127.0.0.1:12111/
[error] electron: Failed to load URL: https://127.0.0.1:12111/ with error: ERR_TIMED_OUT
```

**这能证明"Electron 加载本地页面失败"，但不能区分失败发生在哪一层**（TCP 连不上 / TLS 握手失败 / HTTP 无响应）。

**无法补做**：修复已经生效，现在无法复现故障状态去抓 `curl -v`。

**诚实的结论**：因果链的**结论**（远端连不上导致本地页面失败）有强证据支撑（修复后立刻恢复），但**中间环节（Go 内核未就绪 → HTTP 层无响应）只有时间相关性，没有直接观测**。

评审建议的"保留一份修复前 `curl -v` 输出"是正确的方法论，但对我这次已经错过了时机。**这条应记为方法论教训，而非可补的实验。**

---

## 三、对评审第 10 节 5 个提问的回应

| # | 评审意见 | 我的回应 |
|---|---|---|
| 1 | 因果链成立但缺 HTTP 层证据 | **接受**。见上节。这是方法论缺陷，已不可补 |
| 2 | 方案 B vs C 取舍合理 | 认可。评审确认了"反作弊风险是真实否决理由"，我原本担心的"过度谨慎"可以排除 |
| 3 | 采样不足以支撑结论 | **接受并已补强**。59 次 Established 全指向代理，见上 |
| 4 | 遗漏风险点 | **接受**。详见下节 |
| 5 | 博客版无法评审（未提供） | **理解**。当时确实未提供。当前目录已包含（`01`/`02`/`04` 三份），可供后续评审 |

---

## 四、评审新提的两项小风险 —— 已核实

### ① shim 目录可被替换（评审："风险低但值得知晓"）

实测 ACL：

```
<HOSTNAME>\CodexSandboxUsers:(I)(OI)(CI)(RX)
NT AUTHORITY\SYSTEM:(I)(OI)(CI)(F)
BUILTIN\Administrators:(I)(OI)(CI)(F)
<HOSTNAME>\<you>:(I)(OI)(CI)(F)
```

**确认**：当前用户有完全控制权（F），且该目录位于用户可写的 `%LOCALAPPDATA%` 下。

**评估**：
- 与原 `bin\agy.exe` 的信任级别相同（同一用户目录）
- 需要先攻破当前用户账户才能替换
- **不构成新增攻击面**，但确实"值得知晓"

我同意评审的定性——**风险低，但应在文档里说明**。这属于"完全透明的边界声明"，而非需要修复的问题。

### ② 启动器端口探测延迟（评审："可忽略"）

实测 3 次：

```
第 1 次: 38 ms
第 2 次: 1 ms
第 3 次: 0 ms
```

**确认可忽略**。首次 38ms 是 PowerShell 进程冷启动，之后几乎为 0。

评审估计的 200–500ms 略高，实际更低。**这一项无需优化。**

---

## 五、最终状态复核（修复后重跑全部验证）

```
=== 全局环境 ===
HTTP_PROXY           user=<未设置>  machine=<未设置>
HTTPS_PROXY          user=<未设置>  machine=<未设置>
ALL_PROXY            user=<未设置>  machine=<未设置>
NO_PROXY             user=<未设置>  machine=<未设置>
AGY_PROXY            user=<未设置>  machine=<未设置>
ANTIGRAVITY_PROXY    user=<未设置>  machine=<未设置>

=== PATH ===
Kind = ExpandString
首项 = %LOCALAPPDATA%\agy\shim

=== shim 新逻辑（第 61-62 行）===
GetEnvironmentVariableW(L"HTTP_PROXY", NULL, 0) != 0 ||
GetEnvironmentVariableW(L"http_proxy", NULL, 0) != 0)

=== 快捷方式 ===
桌面（Desktop\Agent）  -> Antigravity-Proxy.cmd  Style=7  ✅
开始菜单               -> Antigravity-Proxy.cmd  Style=7  ✅

=== 功能 ===
agy -p "..."                    -> REGRESSION_OK  ✅
agy --bad-flag (退出码)         -> 2  ✅
3 次真实对话期间 Established     -> 59 次全部 127.0.0.1:7897  ✅
```

---

## 六、对评审结论的回应

评审结论：

> **修复有效，根因判断证据链充分且与本机实测吻合。方案选型合理，全部系统变更可逆且有备份，全局环境未被污染。两项新发现均为 10 分钟内可修完的执行遗漏/代码小偏差，不改变"工作成立、可交付"的结论。**

**我接受这个结论，并感谢这次严格复核。** 评审做了两件我自评时没做到的事：

1. **不只看报告，去查了快捷方式的真实指向** —— 我发现不了这个问题，因为我"以为"自己改过就万事大吉
2. **逐行读了 shim 源码，对照注释找不一致** —— 这是典型的"自评盲区"，作者会下意识认为注释就是实现

## 七、这次复核暴露的方法论问题

复盘我自己的流程，有三个可改进点：

### 1. "改了" ≠ "改对了"，缺少验证闭环

我改完快捷方式后，只验证了桌面那个（因为它在手边），**没有回头验证开始菜单那个**。

**改进**：凡是批量修改多处，必须写一条命令一次性验证全部目标：

```powershell
# 正确的做法：一次性断言所有目标
$targets | ForEach-Object {
    $p = $sh.CreateShortcut($_).TargetPath
    if ($p -notlike '*.cmd') { Write-Warning "未生效: $_" }
}
```

### 2. 注释与实现不一致，没有 automatical 检查

shim 注释说"HTTP_PROXY / HTTPS_PROXY"，代码只检查一个。**这种不一致不会被编译器发现，也不会被运行时发现。**

**改进**：写 C 代码时，注释里的每个声明都该对应一行可验证代码。或者更实际的做法——**注释只写实现真正做的事**，不写意图。

### 3. 采样方法一开始不够严格

第一次"零直连"验证用了 15–24 秒空转采样，得到 24 次命中就下了结论。评审建议的真实对话采样，暴露出 `Bound`/`Listen` 状态混入的问题——**如果我一开始就严格过滤状态，会发现记录数对不上**。

**改进**：采样类验证，必须先验证**采样器本身正确**（用已知流量试跑），再下结论。

---

## 八、遗留事项（更新后）

| # | 事项 | 状态 | 责任 |
|---|---|---|---|
| 1 | 开始菜单快捷方式 | ✅ **已修复** | — |
| 2 | shim 不尊重 HTTP_PROXY | ✅ **已修复并验证** | — |
| 3 | 403 scope（AI Code 不可用） | ✅ **用户重新登录后已解决** | — |
| 4 | 零直连验证 | ✅ **已按建议补强**（59/59 走代理） | — |
| 5 | HTTP 层因果链证据 | ⚠️ **不可补**（故障已消失） | — |
| 6 | 更新器可能还原快捷方式 | ⚠️ **需持续关注** | 用户自查 |
| 7 | shim 目录可替换 | ℹ️ **已披露，无需修复** | — |

### 3. 状态更新（2026-11-08 16:05）：403 已解决

用户已在 Antigravity 客户端完成退出重登。**验证结果：**

| 检查项 | 重登前 | 重登后 |
|---|---|---|
| `SCOPE_INSUFFICIENT` 次数 | 1（旧日志） | **0** |
| `403 Forbidden` 次数 | 1 | **0** |
| E/W 级错误总数 | 有 | **0** |
| `Auth succeeded` | — | **1 次（成功）** |

**验证方法**：清空旧日志 → 重启 Antigravity → 读取全新日志。确保观测到的是重登后的真实状态，而非残留日志。

**agy 侧同步验证**（两者共用凭据）：

```
agy -p "reply with exactly: RELOGIN_OK"  ->  RELOGIN_OK
cli.log 中 SCOPE_INSUFFICIENT: 0
keyringAuth: loaded token, expired=false
```

**结论**：403 scope 问题彻底解决，AI Code 等需要额外 scope 的功能应已恢复。

**回应对评审第 75 行的判断**：评审当时观察到的"逐分钟重试"是准确的（应用运行期间每 60 秒重试一次），但这是**症状而非根因**——根因是旧 token 缺 scope，重新登录即消失。评审将其列为"唯一需要用户行动的实质遗留"是正确判断。

---

## 九、给后续评审者的提示

如果还有下一轮复核，建议重点关注：

1. **工程纪律**：我这次的教训是"改完必须验证全部目标，不只是手边那个"。可以检查我是否在其它地方有同类问题（比如 `02-实践版` 里给的脚本，是否也只覆盖部分场景）

2. **文档与实现一致性**：`01`/`02`/`04` 三份文档里的代码片段，与我实际部署的 `agy-shim.c` / `Antigravity-Proxy.cmd` 是否完全一致？我在写文档时可能做了简化，需要确认简化没有引入错误

3. **文档中的"已验证"声明**：`04-国内使用指南.md` 里我声称验证过 6 个模型名、17 个斜杠命令、7 个子命令。可以抽查这些是否真在二进制里存在

4. **我可能仍然遗漏的**：这次评审教会我，"自评说没有遗漏"本身就是最不可信的声明

---

## 附录：本次修复的完整命令记录

```powershell
# 修复 #1
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agy-shim\repoint-shortcut.ps1"

# 修复 #2（改源码后重编译）
gcc -O2 -s -Wall -o "$env:LOCALAPPDATA\agy\shim\agy.exe" `
    "$env:USERPROFILE\.agy-shim\agy-shim.c" -lws2_32

# 验证
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agy-shim\verify-review.ps1"
```

```bash
# 行为测试 B（验证尊重 HTTP_PROXY）
export HTTP_PROXY=http://127.0.0.1:59999   # 死端口
agy models
# 期望：Error: timed out  （而不是被偷偷改成 7897 后成功）
```
