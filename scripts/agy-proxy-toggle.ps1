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

function Set-UserPathRaw([string]$value) {
    [Microsoft.Win32.Registry]::SetValue(
        'HKEY_CURRENT_USER\Environment', 'Path', $value,
        [Microsoft.Win32.RegistryValueKind]::ExpandString)
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

    Write-Host ''
    Write-Host '--- proxy port probe ---' -ForegroundColor Cyan
    foreach ($port in 7897, 7890, 10809) {
        $ok = $false
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $iar = $t.BeginConnect('127.0.0.1', $port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(300)
            if ($ok) { $t.EndConnect($iar) }
            $t.Close()
        } catch { $ok = $false }
        Write-Host ("  127.0.0.1:{0}  {1}" -f $port, $(if ($ok) { 'open' } else { 'closed' }))
    }
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
