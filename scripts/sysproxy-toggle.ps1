param([switch]$Restore, [switch]$Disable)

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$orig = Get-ItemProperty -Path $key
$stateFile = Join-Path $env:USERPROFILE '.agy-shim\sysproxy-state.json'

if ($Disable) {
    @{ ProxyEnable = $orig.ProxyEnable; ProxyServer = $orig.ProxyServer } |
        ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
    Set-ItemProperty -Path $key -Name ProxyEnable -Value 0
    Write-Host ('system proxy DISABLED (was ProxyEnable=' + $orig.ProxyEnable + ')')
    Write-Host ('saved state -> ' + $stateFile)
    exit 0
}

if ($Restore) {
    if (Test-Path $stateFile) {
        $s = Get-Content $stateFile -Raw | ConvertFrom-Json
        Set-ItemProperty -Path $key -Name ProxyEnable -Value ([int]$s.ProxyEnable)
        if ($s.ProxyServer) {
            Set-ItemProperty -Path $key -Name ProxyServer -Value ([string]$s.ProxyServer)
        }
        Write-Host ('system proxy RESTORED (ProxyEnable=' + $s.ProxyEnable + ', ProxyServer=' + $s.ProxyServer + ')')
    } else {
        Set-ItemProperty -Path $key -Name ProxyEnable -Value 1
        Write-Host 'no state file; set ProxyEnable=1 (default)'
    }
    exit 0
}

# report
$now = Get-ItemProperty -Path $key
Write-Host ('ProxyEnable = ' + $now.ProxyEnable)
Write-Host ('ProxyServer = ' + $now.ProxyServer)
