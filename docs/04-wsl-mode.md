# 04 · WSL 模式下的代理（Antigravity ≥ 2.32.x）

> 适用场景：Antigravity 桌面版报 `dial tcp ...: i/o timeout`，但**本仓库的进程级注入方案看起来完全正常却不生效**。
>
> 结论：从 Antigravity **2.32.x** 起，Go 内核可能不再作为 Windows 子进程运行，而是被放进 **WSL2 的 Linux 环境**里。Windows 的环境变量跨不过 WSL 边界，本仓库的机制对那一层天然无效。

---

## 一、怎么判断你撞的是这个坑

### 一行自查

```powershell
Get-Content "$env:APPDATA\Antigravity\wsl_state.json"
```

| 输出 | 含义 |
|---|---|
| `{"distro":"Ubuntu"}`（或其它发行版） | **WSL 模式** → 本文适用，进程级注入不覆盖 |
| 文件不存在 | Windows 原生模式 → 用 [README](../README.md) 的主线方案 |

### 症状对照

**主方案正常工作时的样子**（`language_server.log`）：

```
ERROR: Post "https://oauth2.googleapis.com/token": dial tcp 192.0.2.10:443: i/o timeout
```

这一类错误，说明注入的 `HTTPS_PROXY` 没被用上。

**但先别急着怀疑 WSL**，按下面顺序确认三件事：

```powershell
# 1. 启动器注入成功了吗？（读目标进程的真实环境变量）
#    若 HTTPS_PROXY 在里面，说明启动器没问题

# 2. 代理端口本身通吗？
Test-NetConnection 127.0.0.1 -Port 7897 -InformationLevel Quiet

# 3. WSL 里的 Go 内核活得下去吗？
wsl -d Ubuntu -e env | Select-String -Pattern proxy
```

如果 1、2 都是好的、3 是空的 —— 就是本文的场景。

---

## 二、根因

### 架构在 2.32.x 变了

旧架构（本仓库主方案针对的）：

```
Antigravity.exe                  ← Electron（Windows）
    └─ language_server.exe       ← Go 内核（Windows 子进程，继承环境变量）✅
```

新架构（WSL 模式）：

```
Antigravity.exe                  ← Electron（Windows）
    └─ WSL2 Ubuntu: language_server   ← Go 内核（Linux 进程！）
            ↑
            Windows 的 HTTP_PROXY 无法穿越这一层 ❌
```

### 为什么 WSL 连不上 Windows 的代理

WSL2 默认是 **NAT 网络模式**，它有独立的网络命名空间：

| 在 WSL 里访问 | 实际指向 |
|---|---|
| `127.0.0.1` | **WSL 自己**，不是 Windows |
| 网关 IP（如 `172.20.0.1`） | Windows 宿主，但只有监听在 `0.0.0.0` 的端口才可达 |

而 mihomo/Clash 默认 `allow-lan: false`，只监听 `127.0.0.1:7897`。于是：

```
WSL → 127.0.0.1:7897          → 命中 WSL 自己，拒绝
WSL → 172.20.0.1:7897         → 被 mihomo 拒绝（未开 allow-lan）
```

WSL 自己也会给出提示：

```
wsl: 检测到 localhost 代理配置，但未镜像到 WSL。NAT 模式下的 WSL 不支持 localhost 代理。
```

### 两条路径都留下痕迹，别被误导

WSL 模式和 Windows 模式会各自生成 hub 描述文件：

```jsonc
// WSL:     /home/<user>/.gemini/antigravity/daemon/hub_44973.json
{ "pid": 498, "httpsPort": 44933, "httpPort": 44973, "lsVersion": "2.32.2" }

// Windows: %USERPROFILE%\.gemini\antigravity\daemon\hub_63817.json
{ "pid": 18072, "httpsPort": 63816, "httpPort": 63817, "lsVersion": "2.32.2" }
```

**两个文件都存在。** 靠**时间戳**判断谁在活跃：写入时间是当前的，才是真在跑的那一侧。

---

## 三、修复：启用 WSL 镜像网络

### 前提

- Windows 11 **22H2 及以上**（build ≥ 22621）

```powershell
[System.Environment]::OSVersion.Version.Build
```

### 操作

新建或编辑 `C:\Users\<你的用户名>\.wslconfig`：

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
```

然后：

```powershell
wsl --shutdown
# 等几秒，再正常启动 Antigravity（走你的启动器 / 快捷方式）
```

### 三项配置各自的作用

| 配置 | 作用 |
|---|---|
| `networkingMode=mirrored` | WSL 与 Windows **共享网络命名空间**，WSL 里的 `127.0.0.1` 就是 Windows 的 `127.0.0.1` |
| `autoProxy=true` | 自动把 Windows 的代理设置导入 WSL 环境变量 |
| `dnsTunneling=true` | 走 Windows DNS 解析，减少镜像模式下的域名解析问题 |

### 验证

```powershell
# 1. 环境变量是否自动出现
wsl -d Ubuntu -e sh -c 'echo HTTPS_PROXY=$HTTPS_PROXY'

# 2. 通过代理能否到达 Google（关键对比）
wsl -d Ubuntu -e curl -s -o /dev/null -w 'proxy=%{http_code} time=%{time_total}s\n' --max-time 10 --proxy http://127.0.0.1:7897 https://oauth2.googleapis.com/token

wsl -d Ubuntu -e curl -s -o /dev/null -w 'direct=%{http_code} time=%{time_total}s\n' --max-time 8 --noproxy '*' https://oauth2.googleapis.com/token
```

**期望结果：**

```
proxy=404  time=0.3s       ← 通了。404 是空 POST 的正常响应，不是失败
direct=000 time=8.0s       ← 超时。这恰恰证明流量确实走了代理
```

> ⚠️ **两个常见误判：**
> 1. **看到 `404` 不要慌**。`oauth2.googleapis.com/token` 不接受空 POST，返回 404 说明**请求已经到达 Google**。判断标准是"有没有超时"，不是状态码。
> 2. **不要用 `/dev/tcp` 探测代理端口**。mihomo 的 HTTP 代理端口不响应裸 TCP 连接，会得到假阴性（`UNREACHABLE`）。用 `curl --proxy` 才准。

### 优点

- **mihomo 配置一行都不用改**，`allow-lan` 保持 `false`，不扩大局域网攻击面
- 不需要改端口、不需要装 TUN 驱动

### 代价与风险

| 项目 | 说明 |
|---|---|
| WSL 会话中断 | `wsl --shutdown` 会杀掉所有 WSL 进程 |
| 端口共享 | 镜像模式下 WSL 与 Windows 共用 `127.0.0.1`，若你在 WSL 跑服务占用 7897 等端口会冲突 |
| 系统要求 | Windows 11 22H2+ |

### 回滚

```powershell
Remove-Item "$env:USERPROFILE\.wslconfig"
wsl --shutdown
```

---

## 四、备选方案（镜像模式不可用时）

开 mihomo 的局域网监听，然后在 WSL 内显式指向网关：

```yaml
# mihomo config.yaml
allow-lan: true
bind-address: "*"
```

```bash
# WSL 内，网关 IP 每次重启可能变化，需动态取
export GW=$(ip route show default | awk '{print $3}')
export HTTPS_PROXY=http://$GW:7897
export HTTP_PROXY=http://$GW:7897
```

**缺点（也是为什么把它列为备选）：**

- `allow-lan: true` 会把代理暴露给**整个局域网**，有安全风险
- 网关 IP 不稳定，重启后要重新设置
- 需要手动维护，不像 `autoProxy` 那样自动跟随

---

## 五、常见误判清单

这些是实际排查中踩到的，单独列出以免重复浪费时间。

### 1. `ELECTRON_RUN_AS_NODE=1` —— "双击没反应"

如果你从 **Electron 应用的子进程环境**里启动 Antigravity（例如从某个 Electron 工具的命令行里 `Start-Process`），会继承这个变量。

后果：`Antigravity.exe` **不启动 GUI，以纯 Node 模式运行后立刻退出**——exit code 0，存活约 250ms，**不写任何日志**。看起来像"安装坏了"。

**判定：**

```powershell
Antigravity.exe --version
```

| 输出 | 含义 |
|---|---|
| `2.32.2` | 正常，应用版本 |
| `v24.22.0` | **被 `ELECTRON_RUN_AS_NODE` 控制**，打印的是 Node 版本 |

**处理：**

```powershell
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
```

> 注意：这个变量通常只存在于特定 shell 会话，不影响用户双击图标启动。先确认注册表是否干净：
> ```powershell
> [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Environment','ELECTRON_RUN_AS_NODE',$null)
> ```

### 2. AntigravityPulse 会改写开始菜单快捷方式

`%LOCALAPPDATA%\AntigravityPulse\settings.json` 里有 `managedLaunch.windowsShortcuts`，会给快捷方式追加：

```
--remote-debugging-port=0 --remote-debugging-address=127.0.0.1
```

而本仓库 `self-heal-shortcuts.ps1` 旧版的健康判定是：

```powershell
# 参数非空 → 判定不健康 → 把参数清掉
if ($current -eq $launcher -and (-not $currentArgs -or $currentArgs.Trim() -eq '')) { continue }
```

**两个程序会反复争夺同一个 `.lnk`。**

若确认是这个问题，处理方式见 [PR #2 的讨论](https://github.com/xiaobaijiadepugongyingpai-coder/antigravity-proxy-fix/pull/2)——那里有把健康判定放宽为"只校验 TargetPath + 保留既有参数"的实现。

### 3. 强杀进程后留下"启动即退出"

用 `Stop-Process -Force` 终结 Electron 进程后，若再次启动"存活 250ms 就退、无日志"，**先排除第 1 条（`ELECTRON_RUN_AS_NODE`）**，再怀疑残留锁。

---

## 六、与主方案的关系

| 组件 | WSL 模式下是否仍然需要 |
|---|---|
| `Antigravity-Proxy.cmd`（桌面启动器） | **仍然需要**。Electron 外壳在 Windows 上，它自己的网络请求（如加载 UI）需要代理 |
| `agy-shim.exe`（CLI 转发器） | **仍然需要**。`agy` 是 Windows 原生 Go 程序，不受 WSL 影响 |
| `self-heal-shortcuts.ps1` | **仍然需要**。快捷方式仍会被更新器重置 |
| `~/.wslconfig` 镜像网络 | **WSL 模式下新增，必需** |

**不要因为加了 `~/.wslconfig` 就拆掉原有部署。** 两者是叠加关系，不是替代关系。

---

## 七、实测环境

| 项目 | 版本 |
|---|---|
| OS | Windows 11 专业版 10.0.26300 |
| Antigravity | 2.32.2（内含 Node v24.22.0） |
| Antigravity CLI | agy 1.5.9 |
| WSL | 3.0.5.0，内核 6.18.58.1-1 |
| 发行版 | Ubuntu |
| 代理 | Clash Verge Rev / mihomo，`mixed-port: 7897`，`allow-lan: false`，TUN 关闭 |

> **验证边界声明：** 已验证的是"WSL 内的网络栈能通过代理到达 Google"（`proxy=404` vs `direct=000`）。
> **未完成**一次完整的 Antigravity Google 登录端到端流程。
> 若你复现后登录仍失败，请附 `language_server.log` 的相关片段再排查。
