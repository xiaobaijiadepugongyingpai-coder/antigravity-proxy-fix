# 给单个程序配置代理：三种方案的取舍与完整实现

> **环境**：Windows 11 · Clash Verge Rev (mihomo v1.19.33)
> **目标**：让指定程序走代理，同时不影响系统上的其它软件
> **结论**：进程级注入是最小侵入的方案

---

## 一、为什么不建议全局变量

最直觉的做法：

```powershell
setx HTTPS_PROXY "http://127.0.0.1:7897"
setx HTTP_PROXY  "http://127.0.0.1:7897"
```

**看起来方便，实际副作用很大。**

### 1.1 四个具体问题

**问题 1：本地回环被代理**

任何访问 `127.0.0.1` 的请求都会送进代理。实测：

```
本地服务 127.0.0.1:18080
  direct    → 200
  via proxy → 502
```

这意味着你本机跑的开发服务、Docker 端口映射、数据库连接**全部失效**。

**问题 2：内网设备失灵**

`192.168.*`、`10.*`、`172.16-31.*` 全部走代理 → NAS、路由器管理页、局域网接口全挂。

**问题 3：单点故障**

代理软件没开的时候，**整个系统断网**。包括：

- 你的 IDE 无法检查更新
- 包管理器无法拉取依赖
- 任何需要联网的工具全部报错

排查起来会非常痛苦——因为你很难第一时间想到"是上次设的那个环境变量"。

**问题 4：污染过深，难以回滚**

`setx` 写入的是用户级环境变量，影响**所有新启动的进程**。一旦忘了这回事，几个月后遇到某个诡异的网络问题，排查成本很高。

### 1.2 正确的做法

**只给需要的程序注入，改完即走，不留全局痕迹。**

```
┌────────────────────────────────────────────┐
│  Windows 环境（干净，无代理变量）            │
│                                             │
│  其它程序 ──直连──> 不受任何影响             │
│                                             │
│  目标程序 ──注入变量──> 127.0.0.1:7897       │
└────────────────────────────────────────────┘
```

---

## 二、三种方案对比

| 方案 | 侵入性 | 覆盖面 | 优点 | 缺点 |
|---|---|---|---|---|
| **A. 进程级注入** | 低 | 仅目标程序 | 零污染，可精确控制 | 每个程序单独配 |
| **B. TUN / 透明代理** | 中 | 全系统 | 一劳永逸，无需配置 | 需装虚拟网卡；游戏反作弊可能冲突 |
| **C. 全局环境变量** | 高 | 全系统 | 配置简单 | 上文列出的四个问题 |

### 2.1 为什么选 A

除非你满足下面所有条件，否则建议用 A：

- 不需要所有程序都走代理
- 机器上有游戏或反作弊软件（TUN 有兼容风险）
- 希望出问题时容易定位

### 2.2 TUN 模式的适用场景

如果你是这样用的，TUN 更省事：

- 全系统都需要代理（浏览器 + 各种工具 + 命令行）
- 机器上没有游戏反作弊
- 不介意装一个虚拟网卡驱动

TUN 的本质是在网络层接管流量，**所有程序（包括 Go / Rust）自动生效**，不需要环境变量。

但代价是：

- 需要管理员权限安装驱动
- 某些反作弊系统会检测到虚拟网卡
- 出问题时影响范围更大（全系统断网）

---

## 三、方案 A 的两种实现

技术约束不同，实现方式也不同：

| 程序类型 | 实现 | 原因 |
|---|---|---|
| **CLI 工具** | 编译原生转发器（exe） | 交互式 TUI；可能被脚本 `subprocess` 调用；需精确透传退出码和 stdio |
| **GUI 应用** | `.cmd` 启动器 | 双击启动，无 stdio 顾虑；`.cmd` 用户可自行修改，无需编译 |

### 3.1 CLI 工具：原生转发器

完整源码（保存为 `shim.c`）：

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

    cands[n++] = L"http://127.0.0.1:7897"; /* Clash Verge mixed-port */
    cands[n++] = L"http://127.0.0.1:7890"; /* Clash for Windows */

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
        *slash = 0;

    /* 真实程序位置 */
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

编译（需要 MinGW-w64）：

```powershell
gcc -O2 -s -Wall -o "shim.exe" shim.c -lws2_32
```

**三个关键设计**：

1. **尊重已有配置**：环境里已有 `HTTPS_PROXY` 就直接放行
2. **探测失败不注入**：代理没开时保持原生行为
3. **退出码透传**：`WaitForSingleObject` + `GetExitCodeProcess`

### 3.2 放入 PATH

```powershell
$shimDir = '%LOCALAPPDATA%\agy\shim'
$key = Get-Item 'HKCU:\Environment'

$raw = $key.GetValue('Path', '',
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

$parts = $raw -split ';' | Where-Object { $_.Trim() -ne '' }
$new = (@($shimDir) + $parts) -join ';'

[Microsoft.Win32.Registry]::SetValue(
    'HKEY_CURRENT_USER\Environment', 'Path', $new,
    [Microsoft.Win32.RegistryValueKind]::ExpandString)
```

目录结构：

```
%LOCALAPPDATA%\agy\
  ├─ shim\shim.exe    ← 转发器（PATH 最前）
  └─ bin\app.exe      ← 原始程序
```

改完重开终端。

### 3.3 GUI 应用：启动器

```bat
@echo off
setlocal

if not defined APP_PROXY set "APP_PROXY=http://127.0.0.1:7897"

REM 本地回环必须绕开
set "NO_PROXY=localhost,127.0.0.1,::1"
set "no_proxy=localhost,127.0.0.1,::1"

set "HTTPS_PROXY=%APP_PROXY%"
set "HTTP_PROXY=%APP_PROXY%"
set "https_proxy=%APP_PROXY%"
set "http_proxy=%APP_PROXY%"

set "APP=%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe"

if not exist "%APP%" (
    echo [ERROR] not found: %APP%
    pause
    exit /b 1
)

REM 探测端口，不通只警告
powershell -NoProfile -Command ^
  "$h=$env:HTTPS_PROXY -replace '^https?://',''; $p=[int]($h -split ':')[-1]; $ok=$false; try{ $c=New-Object Net.Sockets.TcpClient; $r=$c.BeginConnect('127.0.0.1',$p,$null,$null); $ok=$r.AsyncWaitHandle.WaitOne(800); if($ok){$c.EndConnect($r)}; $c.Close() }catch{}; if(-not $ok){ Write-Host ('[WARN] proxy port ' + $p + ' not responding.') -ForegroundColor Yellow; Start-Sleep -Seconds 2 }"

start "" "%APP%"

endlocal
```

改快捷方式：

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
    $s.WindowStyle      = 7              # 最小化
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

## 四、验证隔离性

```powershell
foreach($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY'){
    $u = [Environment]::GetEnvironmentVariable($n,'User')
    $m = [Environment]::GetEnvironmentVariable($n,'Machine')
    "$n  user=$(if($u){$u}else{'<未设置>'})  machine=$(if($m){$m}else{'<未设置>'})"
}
```

**全部应为「未设置」。**

再确认程序确实走到代理：

```powershell
# 按 PID 过滤进程树，看所有 ESTABLISHED 连接
$pids = Get-CimInstance Win32_Process |
        Where-Object { $_.Name -match '你的程序名' } |
        Select-Object -ExpandProperty ProcessId

Get-NetTCPConnection -ErrorAction SilentlyContinue |
    Where-Object { $pids -contains $_.OwningProcess } |
    Select-Object RemoteAddress, RemotePort, State |
    Format-Table -AutoSize
```

期望：只有 `127.0.0.1:7897`（代理端口）和本地回环端口。

---

## 五、代理模式：全局 vs 规则

### 5.1 结论：两种都能用

进程级注入只关心"程序把请求发到代理端口"，**代理内部怎么分流，程序完全无感**。

```
程序 → 注入 HTTPS_PROXY → 127.0.0.1:7897
                                │
                                ├─ 全局模式：全部走选定节点
                                └─ 规则模式：按规则分流
```

### 5.2 为什么推荐规则模式

**性能差异巨大**（实测）：

| 网站 | 全局模式 | 规则模式 | 提升 |
|---|---|---|---|
| baidu | 1.80s | **0.054s** | 快 33 倍 |
| bilibili | 7.58s | **0.208s** | 快 36 倍 |

全局模式下国内站点全部绕道境外再回来，既慢，国内服务还会看到境外 IP 从而触发风控。

### 5.3 规则模式的覆盖验证

关键是规则表里这一条：

```yaml
- DOMAIN-KEYWORD,google,你的节点组
```

关键字匹配，所有 Google 域名（`googleapis.com` / `google.com` / `googleusercontent.com`）全部命中。

末尾还有兜底：

```yaml
- GEOIP,CN,DIRECT      ← 国内 IP 直连
- MATCH,你的节点组      ← 其余全部走代理
```

**即使某个域名漏配，兜底规则也会接住。**

### 5.4 一个容易被忽略的规则顺序问题

有些订阅里会有：

```yaml
- DOMAIN,safebrowsing.googleapis.com,DIRECT   # 第 1259 行
- DOMAIN-KEYWORD,google,你的节点组              # 第 1417 行
```

前者**优先命中**，导致安全浏览接口直连（必然失败）。

**影响**：仅影响该安全检查接口，不影响主功能。想清理可在配置里删掉那条 DIRECT。

---

## 六、账号安全：真实的风险因素

这部分经常被过度恐慌，也经常被过度轻视。按实际影响排序：

### 6.1 风险因素排序

| 因素 | 影响 | 说明 |
|---|---|---|
| **IP 频繁跨国跳变** | ⭐⭐⭐⭐⭐ | 最高危。5 分钟内从台北跳到洛杉矶，任何系统都会标记 |
| **共享 IP 被滥用** | ⭐⭐⭐ | 同一出口多人共用，他人刷接口会拉低 IP 信誉 |
| **机房 IP** | ⭐⭐⭐⭐ | `hosting=true` 的 IP 风险显著更高 |
| **多账号来回切** | ⭐⭐⭐⭐ | 账号关联风控 |
| **脚本高频刷** | ⭐⭐⭐⭐ | 自动化行为判定 |
| **支付地区与 IP 不一致** | ⭐⭐ | 弱信号，但非常普遍 |

### 6.2 IP 质量自检

```powershell
curl.exe -x http://127.0.0.1:7897 -sS `
  "http://ip-api.com/json/?fields=query,country,isp,proxy,hosting"
```

关注两个字段：

- `proxy`：是否被标记为代理 IP
- `hosting`：是否是机房 IP

**理想状态：两个都是 `false`**，且 `isp` 是住宅宽带运营商（如电信、联通、中华电信等）。

### 6.3 IP 稳定性自检

```powershell
for ($i=1; $i -le 5; $i++) {
    curl.exe -x http://127.0.0.1:7897 -sS "http://ip-api.com/line/?fields=query"
    Start-Sleep 5
}
```

**5 次结果应该完全一致。** 如果一直在变，说明节点在自动切换——这是最需要修复的风险点。

### 6.4 降低风险的做法

**必做**：

1. **固定节点**，不要让策略组指向「自动选择」（URLTest 类型会自己跳）
2. **一次配好，不要反复切模式或换节点**
3. 保持登录凭据完整（避免残缺 token 持续产生失败请求）

**建议**：

4. 同一时刻只在一个客户端活跃
5. 不用免费/试用节点跑主账号
6. 尽量长期使用同一个节点

**别做**：

- 频繁切节点
- 多账号来回登
- 脚本高频刷 API
- 分享账号（异地登录会直接触发风控）

### 6.5 平台处理异常的一般顺序

```
CAPTCHA 验证 → 二次验证 → 临时限制 → 才可能升级
```

通常不会一步到位。看到**验证码变多、频繁要求重新登录**，就该检查 IP 是不是在飘。

---

## 七、常见问题

### Q1：代理软件没开时程序还能用吗

能。转发器探测不到端口就不注入，程序保持原生行为（会直连，但不会崩）。

### Q2：程序升级会冲掉配置吗

不会。升级只替换原始程序文件，转发器在独立目录。实测版本升级后仍正常。

### Q3：怎么撤销

**GUI 应用**：把快捷方式目标改回原程序路径。

**CLI 工具**：

```powershell
$d = '%LOCALAPPDATA%\agy\shim'
$key = Get-Item 'HKCU:\Environment'
$raw = $key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$new = (@($raw -split ';' | Where-Object { $_.Trim() -ne '' -and $_.Trim() -ne $d })) -join ';'
[Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\Environment','Path',
    $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
```

**别只删目录而留着 PATH 项**，那样命令会直接"找不到"。

### Q4：端口变了怎么办

转发器支持自定义，设个环境变量即可：

```powershell
setx TARGET_PROXY "http://127.0.0.1:新端口"       # CLI 用
setx APP_PROXY    "http://127.0.0.1:新端口"       # GUI 用
```

---

## 八、总结

| 需求 | 推荐方案 |
|---|---|
| 只有少部分程序需要代理 | **进程级注入**（本文） |
| 全系统都要代理，且无游戏 | TUN 模式 |
| 临时测试 | 命令行前手动 `set` |
| **不推荐** | 全局 `setx` |

**核心原则：范围越小越好，改动越少越好，可逆性越强越好。**

---

## 参考

- Go `net/http.ProxyFromEnvironment`：仅从环境变量读取代理配置，不读系统设置
- Windows 环境变量注册表位置：`HKEY_CURRENT_USER\Environment`
- `CreateProcessW` / `WaitForSingleObject` / `GetExitCodeProcess`：Windows 进程创建与退出码获取
