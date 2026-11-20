$ErrorActionPreference = 'Continue'

# ============================================================
#  Post-fix verification: desktop launcher, shortcuts, self-heal,
#  proxy port latency, global env isolation, and CLI shim/PATH.
#
#  NOTE: this file is intentionally pure ASCII (English only).
#  See repoint-shortcut.ps1 for why.
# ============================================================

$shimHome    = Join-Path $env:USERPROFILE '.agy-shim'
$exeLauncher = Join-Path $shimHome 'AntigravityProxy.exe'
$cmdLauncher = Join-Path $shimHome 'Antigravity-Proxy.cmd'
$confPath    = Join-Path $shimHome 'proxy.conf'
$cliShimDir  = Join-Path $env:LOCALAPPDATA 'agy\shim'
$cliShimExe  = Join-Path $cliShimDir 'agy.exe'

function Resolve-ConfiguredPort {
    if (Test-Path -LiteralPath $confPath) {
        foreach ($line in (Get-Content -LiteralPath $confPath -ErrorAction SilentlyContinue)) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
            if ($t -match ':(\d{2,5})\b') { return [int]$Matches[1] }
            if ($t -match '^\d{2,5}$') { return [int]$t }
        }
    }
    if (Test-Path -LiteralPath $cmdLauncher) {
        $m = Select-String -LiteralPath $cmdLauncher -Pattern 'ANTIGRAVITY_PROXY=.*:(\d{2,5})' | Select-Object -First 1
        if ($m) { return [int]$m.Matches[0].Groups[1].Value }
    }
    return 7897
}

Write-Host '=== 1. desktop launcher & config ==='
if (Test-Path -LiteralPath $exeLauncher) {
    $ver = (Get-Item -LiteralPath $exeLauncher).VersionInfo.FileVersion
    Write-Host ("  AntigravityProxy.exe : [found] v{0}" -f $ver) -ForegroundColor Green
} else {
    Write-Host '  AntigravityProxy.exe : [not built] (run scripts\build-desktop-launcher.ps1)' -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $cmdLauncher) {
    $hasForward = [bool](Select-String -LiteralPath $cmdLauncher -Pattern 'start "" "%APP%" %\*\s*$' -Quiet)
    Write-Host ("  Antigravity-Proxy.cmd: [found] arg-forwarding={0}" -f $hasForward)
}
if (Test-Path -LiteralPath $confPath) {
    $confLine = (Get-Content -LiteralPath $confPath | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') } | Select-Object -First 1)
    Write-Host ("  proxy.conf           : {0}" -f $confLine)
} else {
    Write-Host '  proxy.conf           : [not set; auto-probes 7897 -> 7890 -> 10809]'
}

Write-Host ''
Write-Host '=== 2. desktop shortcuts ==='
$expectedLauncher = if (Test-Path -LiteralPath $exeLauncher) { $exeLauncher } else { $cmdLauncher }
$sh = New-Object -ComObject WScript.Shell
$startMenuLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk'
$shortcuts = @(
    (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Agent\Antigravity.lnk'),
    $startMenuLnk,
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Antigravity.lnk')
)
foreach ($t in $shortcuts) {
    if (-not (Test-Path -LiteralPath $t)) { continue }
    try {
        $s = $sh.CreateShortcut($t)
        $status = if ($s.TargetPath -eq $expectedLauncher) { 'OK  ' } else { 'WARN' }
        $color  = if ($status -eq 'OK  ') { 'Green' } else { 'Yellow' }
        $ro = [bool]((Get-Item -LiteralPath $t).Attributes -band [IO.FileAttributes]::ReadOnly)
        $flags = if ($ro) { '  [protected +R]' } else { '' }
        Write-Host ("  {0} {1}{2}" -f $status, $t, $flags) -ForegroundColor $color
        Write-Host ("       target: {0}" -f $s.TargetPath)
        Write-Host ("       args  : {0}" -f $(if ($s.Arguments) { $s.Arguments } else { '<empty>' }))
        if ($status -eq 'WARN' -and $t.Equals($startMenuLnk, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host '       hint  : Electron Toast notifications or updates can reset Start Menu shortcut.' -ForegroundColor Yellow
            Write-Host '               Run: powershell -ExecutionPolicy Bypass -File .\scripts\repoint-shortcut.ps1 -AddDebugPort -ProtectStartMenu' -ForegroundColor Yellow
        }
    } catch {
        Write-Host ("  FAIL {0} -> {1}" -f $t, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '=== 3. self-heal startup hook ==='
$healPs1 = Join-Path $shimHome 'self-heal-shortcuts.ps1'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$healVbs = Join-Path $startupDir 'self-heal-shortcuts.vbs'
Write-Host ("  self-heal-shortcuts.ps1 : {0}" -f $(if (Test-Path -LiteralPath $healPs1) { '[found]' } else { '[missing]' }))
Write-Host ("  Startup VBS             : {0}" -f $(if (Test-Path -LiteralPath $healVbs) { '[found]' } else { '[missing]' }))

$probePort = Resolve-ConfiguredPort
Write-Host ''
Write-Host ("=== 4. proxy port probe latency (127.0.0.1:{0}, 3 runs) ===" -f $probePort)
for ($i = 1; $i -le 3; $i++) {
    $t0 = Get-Date
    $ok = $false
    try {
        $c = New-Object Net.Sockets.TcpClient
        $r = $c.BeginConnect('127.0.0.1', $probePort, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne(800)
        if ($ok) { $c.EndConnect($r) }
        $c.Close()
    } catch { }
    $ms = ((Get-Date) - $t0).TotalMilliseconds
    Write-Host ("  run {0}: {1:N0} ms  (reachable={2})" -f $i, $ms, $ok)
}

Write-Host ''
Write-Host '=== 5. global environment check (should all be unset) ==='
foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','AGY_PROXY','ANTIGRAVITY_PROXY') {
    $u = [Environment]::GetEnvironmentVariable($n, 'User')
    $m = [Environment]::GetEnvironmentVariable($n, 'Machine')
    Write-Host ("  {0,-20} user={1,-12} machine={2}" -f $n,
        $(if ($u) { $u } else { '<unset>' }),
        $(if ($m) { $m } else { '<unset>' }))
}

Write-Host ''
Write-Host '=== 6. CLI shim (agy) & PATH ==='
$k = Get-Item 'HKCU:\Environment'
Write-Host ("  PATH Kind   = " + $k.GetValueKind('Path'))
$raw = $k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
Write-Host ("  first entry = " + ($raw -split ';')[0])
$resolved = (Get-Command agy -ErrorAction SilentlyContinue).Source
Write-Host ("  resolved    = " + $(if ($resolved) { $resolved } else { '<agy not on PATH>' }))
if (Test-Path -LiteralPath $cliShimExe) {
    $verOut = & $cliShimExe --version 2>&1
    Write-Host ("  shim exe    = {0} ({1})" -f $cliShimExe, $verOut)
    if ($resolved -and -not $resolved.Equals($cliShimExe, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host '  [WARN] Current shell PATH still resolves to the unproxied agy binary!' -ForegroundColor Yellow
        Write-Host '         Open a NEW terminal (or re-run scripts\build-cli-shim.ps1 -AddToPath to broadcast WM_SETTINGCHANGE).' -ForegroundColor Yellow
    }
    icacls $cliShimDir 2>&1 | Select-Object -First 6
} else {
    Write-Host ("  shim exe    = [not installed] ({0})" -f $cliShimExe)
}
