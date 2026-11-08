$ErrorActionPreference = 'Continue'

Write-Host '=== 1. shim 目录 ACL ==='
$shim = Join-Path $env:LOCALAPPDATA 'agy\shim'
icacls $shim 2>&1 | Select-Object -First 8

Write-Host ''
Write-Host '=== 2. 启动器端口探测耗时（3 次）==='
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
    Write-Host ("  第 {0} 次: {1:N0} ms  (可达={2})" -f $i, $ms, $ok)
}

Write-Host ''
Write-Host '=== 3. 修复后全局环境复核 ==='
foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','AGY_PROXY','ANTIGRAVITY_PROXY') {
    $u = [Environment]::GetEnvironmentVariable($n, 'User')
    $m = [Environment]::GetEnvironmentVariable($n, 'Machine')
    Write-Host ("  {0,-20} user={1,-12} machine={2}" -f $n,
        $(if ($u) { $u } else { '<未设置>' }),
        $(if ($m) { $m } else { '<未设置>' }))
}

Write-Host ''
Write-Host '=== 4. PATH 类型与首项 ==='
$k = Get-Item 'HKCU:\Environment'
Write-Host ("  Kind = " + $k.GetValueKind('Path'))
$raw = $k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
Write-Host ("  首项 = " + ($raw -split ';')[0])

Write-Host ''
Write-Host '=== 5. shim 源文件的 HTTP_PROXY 检查（新逻辑）==='
Select-String -Path "$env:USERPROFILE\.agy-shim\agy-shim.c" -Pattern 'HTTP_PROXY' |
    ForEach-Object { "  行 $($_.LineNumber): $($_.Line.Trim())" }
