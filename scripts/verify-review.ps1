$ErrorActionPreference = 'Continue'

# ============================================================
#  Post-fix verification: shim deployment, isolation, PATH.
#
#  NOTE: this file is intentionally pure ASCII (English only).
#  See repoint-shortcut.ps1 for why.
# ============================================================

Write-Host '=== 1. shim directory ACL ==='
$shim = Join-Path $env:LOCALAPPDATA 'agy\shim'
icacls $shim 2>&1 | Select-Object -First 8

Write-Host ''
Write-Host '=== 2. launcher port probe latency (3 runs) ==='
for ($i = 1; $i -le 3; $i++) {
    $t0 = Get-Date
    $ok = $false
    try {
        $c = New-Object Net.Sockets.TcpClient
        $r = $c.BeginConnect('127.0.0.1', 7897, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne(800)
        if ($ok) { $c.EndConnect($r) }
        $c.Close()
    } catch { }
    $ms = ((Get-Date) - $t0).TotalMilliseconds
    Write-Host ("  run {0}: {1:N0} ms  (reachable={2})" -f $i, $ms, $ok)
}

Write-Host ''
Write-Host '=== 3. global environment check (should all be unset) ==='
foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','AGY_PROXY','ANTIGRAVITY_PROXY') {
    $u = [Environment]::GetEnvironmentVariable($n, 'User')
    $m = [Environment]::GetEnvironmentVariable($n, 'Machine')
    Write-Host ("  {0,-20} user={1,-12} machine={2}" -f $n,
        $(if ($u) { $u } else { '<unset>' }),
        $(if ($m) { $m } else { '<unset>' }))
}

Write-Host ''
Write-Host '=== 4. PATH value kind and first entry ==='
$k = Get-Item 'HKCU:\Environment'
Write-Host ("  Kind = " + $k.GetValueKind('Path'))
$raw = $k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
Write-Host ("  first entry = " + ($raw -split ';')[0])

Write-Host ''
Write-Host '=== 5. shim source: HTTP_PROXY checks ==='
Select-String -Path "$env:USERPROFILE\.agy-shim\agy-shim.c" -Pattern 'HTTP_PROXY' |
    ForEach-Object { "  line $($_.LineNumber): $($_.Line.Trim())" }
