# ============================================================
#  agy proxy toggle: enable / disable / status
#
#  How it works: a small shim (agy.exe) is placed at the front of
#  PATH. It injects HTTPS_PROXY into the agy child process only,
#  leaving every other program untouched.
#
#  No admin rights needed (only HKCU is modified).
#
#  NOTE: this file is intentionally pure ASCII (English only).
#  Non-ASCII text in a .ps1 without a BOM is misread by
#  Windows PowerShell 5.1 under a non-UTF8 ANSI code page.
# ============================================================

$ErrorActionPreference = 'Stop'
$shimDir = Join-Path $env:LOCALAPPDATA 'agy\shim'
$regPath = 'HKCU:\Environment'

function Get-UserPathRaw {
    $k = Get-Item $regPath
    return $k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Send-EnvChangeBroadcast {
    try {
        if (-not ('Win32.AgEnvNotify' -as [type])) {
            $sig = @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeoutW(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
            Add-Type -Namespace Win32 -Name AgEnvNotify -MemberDefinition $sig -ErrorAction Stop | Out-Null
        }
        $res = [UIntPtr]::Zero
        [Win32.AgEnvNotify]::SendMessageTimeoutW([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$res) | Out-Null
    } catch { }
}

function Set-UserPathRaw([string]$value) {
    [Microsoft.Win32.Registry]::SetValue(
        'HKEY_CURRENT_USER\Environment', 'Path', $value,
        [Microsoft.Win32.RegistryValueKind]::ExpandString)
    Send-EnvChangeBroadcast
}

function ConvertTo-ProxyHostPort([string]$raw) {
    if (-not $raw) { return $null }
    $s = $raw.Trim().Trim('"').Trim("'")
    if (-not $s) { return $null }
    if ($s -match '^\d{1,5}$') {
        $p = [int]$s
        if ($p -ge 1 -and $p -le 65535) {
            return @{ Host = '127.0.0.1'; Port = $p }
        }
        return $null
    }
    if ($s -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $s = 'http://' + $s
    }
    try {
        $u = [Uri]$s
        if ($u.Host -and $u.Port -ge 1 -and $u.Port -le 65535) {
            return @{ Host = $u.Host.Trim('[', ']'); Port = $u.Port }
        }
    } catch { }
    return $null
}

function Read-ProxyConfRaw([string]$confPath) {
    if (-not (Test-Path -LiteralPath $confPath)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $confPath -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -gt 0) {
            $k = $t.Substring(0, $eq).Trim().ToUpperInvariant()
            if ($k -in @('AGY_PROXY', 'ANTIGRAVITY_PROXY', 'HTTPS_PROXY', 'HTTP_PROXY', 'PROXY')) {
                $t = $t.Substring($eq + 1).Trim()
            }
        }
        return $t
    }
    return $null
}

function Resolve-ProxyEndpoints([string]$confPath) {
    $candidates = @()
    $envVal = [Environment]::GetEnvironmentVariable('AGY_PROXY', 'Process')
    if ($envVal) {
        $hp = ConvertTo-ProxyHostPort $envVal
        if ($hp) { $candidates += @{ Host = $hp.Host; Port = $hp.Port; Tag = '[from AGY_PROXY]' } }
    }
    $confRaw = Read-ProxyConfRaw $confPath
    if ($confRaw) {
        $hp = ConvertTo-ProxyHostPort $confRaw
        if ($hp) { $candidates += @{ Host = $hp.Host; Port = $hp.Port; Tag = '[from proxy.conf]' } }
    }
    foreach ($port in 7897, 7890, 10809) {
        $candidates += @{ Host = '127.0.0.1'; Port = $port; Tag = '[fallback]' }
    }

    $seen = @{}
    $unique = @()
    foreach ($c in $candidates) {
        $key = "{0}:{1}" -f $c.Host.ToLowerInvariant(), $c.Port
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $c
        }
    }
    return ,$unique
}

function Show-Status {
    Write-Host ''
    Write-Host '--- shim status ---' -ForegroundColor Cyan
    $raw = Get-UserPathRaw
    $parts = @($raw -split ';' | Where-Object { $_.Trim() -ne '' })
    $first = if ($parts.Count -gt 0) { $parts[0] } else { '' }
    $expandedFirst = [Environment]::ExpandEnvironmentVariables($first)
    if ($expandedFirst -eq $shimDir) {
        Write-Host '  enabled (shim is first in PATH)' -ForegroundColor Green
    } elseif ($parts -contains '%LOCALAPPDATA%\agy\shim' -or $parts -contains $shimDir) {
        Write-Host '  present but not first; another agy copy may win' -ForegroundColor Yellow
    } else {
        Write-Host '  disabled (agy runs the original binary, direct connection)' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '--- binary locations ---' -ForegroundColor Cyan
    $shimExe = Join-Path $shimDir 'agy.exe'
    $realExe = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
    Write-Host ('  shim     : ' + $shimExe + '  ' + $(if (Test-Path $shimExe) { '[found]' } else { '[MISSING]' }))
    Write-Host ('  real agy : ' + $realExe + '  ' + $(if (Test-Path $realExe) { '[found]' } else { '[MISSING]' }))
    Write-Host ('  this shell resolves to: ' + $(
        $c = Get-Command agy -ErrorAction SilentlyContinue
        if ($c) { $c.Source } else { '<agy not on PATH>' }))

    Write-Host ''
    Write-Host '--- global proxy vars (should all be empty) ---' -ForegroundColor Cyan
    foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY') {
        $v = [Environment]::GetEnvironmentVariable($n, 'User')
        $m = [Environment]::GetEnvironmentVariable($n, 'Machine')
        $sv = if ($v) { $v } else { '<unset>' }
        $sm = if ($m) { $m } else { '<unset>' }
        Write-Host ("  {0,-12} user={1}  machine={2}" -f $n, $sv, $sm)
    }

    $confPath = Join-Path $env:USERPROFILE '.agy-shim\proxy.conf'
    $confRaw = Read-ProxyConfRaw $confPath
    Write-Host ''
    Write-Host '--- proxy config & endpoint probe ---' -ForegroundColor Cyan
    if ($confRaw) {
        Write-Host ("  proxy.conf : {0} -> {1}" -f $confPath, $confRaw)
    } else {
        Write-Host ("  proxy.conf : {0} [not set]" -f $confPath)
    }
    foreach ($ep in (Resolve-ProxyEndpoints $confPath)) {
        $ok = $false
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $iar = $t.BeginConnect($ep.Host, $ep.Port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(300)
            if ($ok) { $t.EndConnect($iar) }
            $t.Close()
        } catch { $ok = $false }
        $label = "{0}:{1}" -f $ep.Host, $ep.Port
        $state = if ($ok) { 'open' } else { 'closed' }
        Write-Host ("  {0,-22} {1,-7} {2}" -f $label, $state, $ep.Tag)
    }
    Write-Host '  (fallback ports are only used when proxy.conf is unset or unreachable)'
}

function Enable-Shim {
    if (-not (Test-Path (Join-Path $shimDir 'agy.exe'))) {
        Write-Host 'shim binary not found; cannot enable.' -ForegroundColor Red
        Write-Host ('  expected: ' + (Join-Path $shimDir 'agy.exe'))
        return
    }
    $raw = Get-UserPathRaw
    $parts = @($raw -split ';' | Where-Object { $_.Trim() -ne '' })
    $token = '%LOCALAPPDATA%\agy\shim'
    $filtered = @($parts | Where-Object { $_.Trim() -ne $token -and $_.Trim() -ne $shimDir })
    $new = (@($token) + $filtered) -join ';'
    Set-UserPathRaw $new
    Write-Host 'Enabled. Close all terminals and open a new one.' -ForegroundColor Green
}

function Disable-Shim {
    $raw = Get-UserPathRaw
    $parts = @($raw -split ';' | Where-Object { $_.Trim() -ne '' })
    $token = '%LOCALAPPDATA%\agy\shim'
    $filtered = @($parts | Where-Object { $_.Trim() -ne $token -and $_.Trim() -ne $shimDir })
    $new = $filtered -join ';'
    Set-UserPathRaw $new
    Write-Host ("Disabled. PATH now has {0} entries. Restart your terminals." -f $filtered.Count) -ForegroundColor Green
}

# ---------------- main ----------------
Write-Host ''
Write-Host '===== agy proxy toggle =====' -ForegroundColor White
Write-Host ('  shim dir: ' + $shimDir)
Write-Host ''
Write-Host '  1 = enable  (agy goes through the proxy)'
Write-Host '  2 = disable (restore the original behavior)'
Write-Host '  3 = status only'
Write-Host ''

$choice = Read-Host 'Enter 1 / 2 / 3 and press Enter'
switch ($choice.Trim()) {
    '1' { Enable-Shim; Show-Status }
    '2' { Disable-Shim; Show-Status }
    default { Show-Status }
}

Write-Host ''
Read-Host 'Press Enter to exit' | Out-Null
