$ErrorActionPreference = 'Stop'

# ============================================================
#  改写 Antigravity 快捷方式，指向带代理的启动器
#
#  为什么需要：Antigravity 的 Go 内核只读环境变量代理，
#  不认 Windows 系统代理。启动器负责注入，本脚本负责让
#  快捷方式调用启动器而不是原始 exe。
# ============================================================

$launcher = Join-Path $env:USERPROFILE '.agy-shim\Antigravity-Proxy.cmd'
$exe      = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'

if (-not (Test-Path $launcher)) {
    Write-Warning "launcher not found: $launcher"
    Write-Warning '请先把 Antigravity-Proxy.cmd 放到该位置'
    exit 1
}
if (-not (Test-Path $exe)) {
    Write-Warning "Antigravity.exe not found: $exe"
    exit 1
}

# 桌面快捷方式可能被用户移动到子目录，都尝试一下
$targets = @(
    (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Agent\Antigravity.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk')
)

$sh = New-Object -ComObject WScript.Shell

foreach ($t in $targets) {
    if (-not (Test-Path $t)) {
        Write-Host ("skip (not found): " + $t)
        continue
    }

    $s = $sh.CreateShortcut($t)
    $s.TargetPath       = $launcher
    $s.Arguments        = ''
    $s.WorkingDirectory = Split-Path $launcher
    $s.IconLocation     = $exe + ',0'    # 保留原图标
    $s.WindowStyle      = 7              # 最小化，避免 cmd 黑框闪
    $s.Description      = 'Antigravity (with proxy)'
    $s.Save()

    Write-Host ("updated: " + $t)
}

# 改完必须逐一验证 —— 批量修改最容易漏掉其中一个
Write-Host ''
Write-Host '--- verify ---'
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
if ($bad) {
    Write-Warning "$bad 个快捷方式未生效"
    exit 1
}
Write-Host '全部生效' -ForegroundColor Green
