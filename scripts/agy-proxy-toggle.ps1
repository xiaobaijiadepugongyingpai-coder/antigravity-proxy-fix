# ============================================================
#  只让 agy 走代理：启用 / 撤销 / 查看状态
#  原理：PATH 最前面放一个 agy.exe 转发器(shim)，它只给 agy
#        子进程注入 HTTPS_PROXY，其它程序一概不碰。
#  不需要管理员权限（只改当前用户 HKCU）
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
    Write-Host '--- shim 状态 ---' -ForegroundColor Cyan
    $raw = Get-UserPathRaw
    $parts = @($raw -split ';' | Where-Object { $_.Trim() -ne '' })
    $first = if ($parts.Count -gt 0) { $parts[0] } else { '' }
    $expandedFirst = [Environment]::ExpandEnvironmentVariables($first)
    if ($expandedFirst -eq $shimDir) {
        Write-Host '  已启用（shim 在 PATH 最前面）' -ForegroundColor Green
    } elseif ($parts -contains '%LOCALAPPDATA%\agy\shim' -or $parts -contains $shimDir) {
        Write-Host '  已启用，但不在最前；其它 agy 副本可能抢先' -ForegroundColor Yellow
    } else {
        Write-Host '  未启用（agy 走原始程序，直连）' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '--- 程序位置 ---' -ForegroundColor Cyan
    $shimExe = Join-Path $shimDir 'agy.exe'
    $realExe = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
    Write-Host ('  shim      : ' + $shimExe + '  ' + $(if (Test-Path $shimExe) { '[存在]' } else { '[缺失!]' }))
    Write-Host ('  真实 agy  : ' + $realExe + '  ' + $(if (Test-Path $realExe) { '[存在]' } else { '[缺失!]' }))
    Write-Host ('  本窗口解析: ' + $(
        $c = Get-Command agy -ErrorAction SilentlyContinue
        if ($c) { $c.Source } else { '<PATH 里没有 agy>' }))

    Write-Host ''
    Write-Host '--- 全局代理变量（应为空 = 没有污染其它程序）---' -ForegroundColor Cyan
    foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY') {
        $v = [Environment]::GetEnvironmentVariable($n, 'User')
        $m = [Environment]::GetEnvironmentVariable($n, 'Machine')
        $sv = if ($v) { $v } else { '<未设置>' }
        $sm = if ($m) { $m } else { '<未设置>' }
        Write-Host ("  {0,-12} user={1}  machine={2}" -f $n, $sv, $sm)
    }

    Write-Host ''
    Write-Host '--- 代理端口探测 ---' -ForegroundColor Cyan
    foreach ($port in 7897, 7890, 10809) {
        $ok = $false
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $iar = $t.BeginConnect('127.0.0.1', $port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(300)
            if ($ok) { $t.EndConnect($iar) }
            $t.Close()
        } catch { $ok = $false }
        Write-Host ("  127.0.0.1:{0}  {1}" -f $port, $(if ($ok) { '可用' } else { '不通' }))
    }
}

function Enable-Shim {
    if (-not (Test-Path (Join-Path $shimDir 'agy.exe'))) {
        Write-Host '找不到 shim 程序，无法启用。' -ForegroundColor Red
        Write-Host ('  期望路径: ' + (Join-Path $shimDir 'agy.exe'))
        return
    }
    $raw = Get-UserPathRaw
    $parts = @($raw -split ';' | Where-Object { $_.Trim() -ne '' })
    $token = '%LOCALAPPDATA%\agy\shim'
    $filtered = @($parts | Where-Object { $_.Trim() -ne $token -and $_.Trim() -ne $shimDir })
    $new = (@($token) + $filtered) -join ';'
    Set-UserPathRaw $new
    Write-Host '已启用。请关掉所有终端重新打开。' -ForegroundColor Green
}

function Disable-Shim {
    $raw = Get-UserPathRaw
    $parts = @($raw -split ';' | Where-Object { $_.Trim() -ne '' })
    $token = '%LOCALAPPDATA%\agy\shim'
    $filtered = @($parts | Where-Object { $_.Trim() -ne $token -and $_.Trim() -ne $shimDir })
    $new = $filtered -join ';'
    Set-UserPathRaw $new
    Write-Host ("已撤销，PATH 现在有 {0} 项。请关掉所有终端重新打开。" -f $filtered.Count) -ForegroundColor Green
}

# ---------------- 主流程 ----------------
Write-Host ''
Write-Host '===== agy 代理开关 =====' -ForegroundColor White
Write-Host ('  shim 目录: ' + $shimDir)
Write-Host ''
Write-Host '  1 = 启用（agy 走代理）'
Write-Host '  2 = 撤销（恢复原状）'
Write-Host '  3 = 只看状态'
Write-Host ''

$choice = Read-Host '请输入 1 / 2 / 3 然后回车'
switch ($choice.Trim()) {
    '1' { Enable-Shim; Show-Status }
    '2' { Disable-Shim; Show-Status }
    default { Show-Status }
}

Write-Host ''
Read-Host '按回车退出' | Out-Null
