param(
    [string]$ProxyUrl = '',
    [int]$TimeoutSec = 10
)

$ErrorActionPreference = 'Continue'

# ============================================================
#  One-click diagnostic for Clash mode, active nodes, and
#  per-domain Google / Antigravity upstream reachability.
#
#  Automates the diagnosis tree in docs/HANDOVER.md (Sec 5 & 8):
#    1. Resolve proxy address & check local port reachability
#    2. Query Clash/mihomo mode and Selector/URLTest groups
#    3. Probe cloudcode-pa / oauth2 / accounts / google via curl
#    4. Print actionable verdict (config vs node vs mode issue)
#
#  NOTE: this file is intentionally pure ASCII (English only).
# ============================================================

function Normalize-ProxyUrl([string]$raw) {
    if (-not $raw) { return $null }
    $s = $raw.Trim().Trim('"', "'").Trim()
    if ($s -eq '') { return $null }
    if ($s -match '^\d+$') {
        $p = [int]$s
        if ($p -ge 1 -and $p -le 65535) { return ('http://127.0.0.1:' + $p) }
        return $null
    }
    if ($s -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $s = 'http://' + $s
    }
    try {
        $u = [Uri]$s
        if ($u.Host -and $u.Port -ge 1 -and $u.Port -le 65535) { return $s }
    } catch { }
    return $null
}

function Read-ProxyConf([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
        if ($t -match '^(ANTIGRAVITY_PROXY|AGY_PROXY|HTTPS_PROXY|HTTP_PROXY|PROXY)\s*=\s*(.+)$') {
            $t = $Matches[2]
        }
        $n = Normalize-ProxyUrl $t
        if ($n) { return $n }
    }
    return $null
}

function Test-TcpPort([string]$proxyUrl, [int]$timeoutMs = 500) {
    try {
        $u = [Uri]$proxyUrl
        $t0 = Get-Date
        $c = New-Object System.Net.Sockets.TcpClient
        $r = $c.BeginConnect($u.Host, $u.Port, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne($timeoutMs)
        if ($ok) { $c.EndConnect($r) }
        $connected = $ok -and $c.Connected
        $c.Close()
        $ms = [math]::Round(((Get-Date) - $t0).TotalMilliseconds)
        return [PSCustomObject]@{ Ok = $connected; Ms = $ms; Host = $u.Host; Port = $u.Port }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Ms = -1; Host = ''; Port = 0 }
    }
}

Write-Host '=== 1. Proxy discovery ===' -ForegroundColor Cyan
$candidates = New-Object System.Collections.Generic.List[string]
foreach ($c in @(
    (Normalize-ProxyUrl $ProxyUrl),
    (Normalize-ProxyUrl $env:ANTIGRAVITY_PROXY),
    (Normalize-ProxyUrl $env:AGY_PROXY),
    (Read-ProxyConf (Join-Path $env:USERPROFILE '.agy-shim\proxy.conf')),
    'http://127.0.0.1:7897',
    'http://127.0.0.1:7890',
    'http://127.0.0.1:10809'
)) {
    if ($c -and -not $candidates.Contains($c)) {
        $candidates.Add($c)
    }
}

$chosenProxy = $null
foreach ($cand in $candidates) {
    $res = Test-TcpPort $cand
    if ($res.Ok) {
        $chosenProxy = $cand
        Write-Host ("  REACHABLE : {0} ({1} ms)" -f $cand, $res.Ms) -ForegroundColor Green
        break
    } else {
        Write-Host ("  closed    : {0}" -f $cand) -ForegroundColor DarkGray
    }
}

if (-not $chosenProxy) {
    Write-Host ''
    Write-Host '[VERDICT] No local proxy port is reachable. Check whether Clash / proxy client is running.' -ForegroundColor Red
    exit 2
}

function Invoke-Utf8Process([string]$fileName, [string]$arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $fileName
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8

    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $stdOut = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $stdErr = $errTask.GetAwaiter().GetResult()

    $combined = @()
    if ($stdOut) { $combined += ($stdOut -split "`r?`n") }
    if ($stdErr) { $combined += ($stdErr -split "`r?`n") }
    return ,$combined
}

Write-Host ''
Write-Host '=== 2. Clash / mihomo mode & active groups ===' -ForegroundColor Cyan
$queryScript = Join-Path $PSScriptRoot 'query-mihomo.py'
$pyCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pyCmd) { $pyCmd = Get-Command python3 -ErrorAction SilentlyContinue }

if ($pyCmd -and (Test-Path -LiteralPath $queryScript)) {
    $quotedScript = '"' + $queryScript + '"'
    $cfgOut = Invoke-Utf8Process $pyCmd.Source ($quotedScript + ' configs')
    $cfgOut | ForEach-Object { if ($_ -ne '') { Write-Host $_ } }
    Write-Host ''
    $proxyOut = Invoke-Utf8Process $pyCmd.Source ($quotedScript + ' proxies')
    $proxyOut | ForEach-Object { Write-Host $_ }

    # Check for common trap selections in GLOBAL / Selectors (DIRECT, REJECT, traffic banners)
    $suspicious = @($proxyOut | Where-Object {
        $_ -match '->\s*(DIRECT|REJECT)\s' -or
        $_ -match '->.*\b(GB|TB|MB|Traffic|Expire|Reset)\b'
    })
    if ($suspicious.Count -gt 0) {
        Write-Host ''
        Write-Host '[WARN] Suspicious group selection detected (DIRECT / REJECT / traffic-info node):' -ForegroundColor Yellow
        $suspicious | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor Yellow }
    }
} else {
    Write-Host '  (skip: python or scripts/query-mihomo.py not available)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host ('=== 3. Per-domain reachability via ' + $chosenProxy + ' ===') -ForegroundColor Cyan
$curlExe = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curlExe) {
    Write-Host '  [ERROR] curl.exe not found; cannot run per-domain TLS probes.' -ForegroundColor Red
    exit 1
}

$domains = @(
    'cloudcode-pa.googleapis.com',
    'daily-cloudcode-pa.googleapis.com',
    'oauth2.googleapis.com',
    'accounts.google.com',
    'www.google.com'
)

$results = @()
Write-Host ("  {0,-36} {1,-6} {2,-10} {3}" -f 'Domain', 'Code', 'TLS(s)', 'Total(s)')
foreach ($d in $domains) {
    $raw = & $curlExe.Source -x $chosenProxy -s -o NUL -w '%{http_code}|%{time_appconnect}|%{time_total}' --max-time $TimeoutSec ("https://" + $d + "/")
    $parts = ($raw -as [string]) -split '\|'
    $code  = if ($parts.Count -ge 1 -and $parts[0]) { $parts[0] } else { '000' }
    $tls   = if ($parts.Count -ge 2 -and $parts[1]) { $parts[1] } else { '0' }
    $total = if ($parts.Count -ge 3 -and $parts[2]) { $parts[2] } else { '0' }
    $color = if ($code -eq '000') { 'Red' } else { 'Green' }
    Write-Host ("  {0,-36} {1,-6} {2,-10} {3}" -f $d, $code, $tls, $total) -ForegroundColor $color
    $results += [PSCustomObject]@{ Domain = $d; Code = $code; Tls = [double]$tls; Total = [double]$total }
}

Write-Host ''
Write-Host '=== 4. Verdict ===' -ForegroundColor Cyan
$allFailed = @($results | Where-Object { $_.Code -ne '000' }).Count -eq 0
$aiFailed  = @($results | Where-Object { $_.Domain -like '*cloudcode-pa*' -and $_.Code -eq '000' }).Count
$coreOk    = @($results | Where-Object { $_.Domain -notlike '*cloudcode-pa*' -and $_.Code -ne '000' }).Count
$slowAi    = @($results | Where-Object { $_.Domain -eq 'cloudcode-pa.googleapis.com' -and $_.Code -ne '000' -and $_.Tls -gt 1.0 }).Count

if ($allFailed) {
    Write-Host '[FAIL] All Google domains returned 000 via proxy.' -ForegroundColor Red
    Write-Host '       Likely cause: active Clash node is down, GLOBAL is on DIRECT/REJECT or a fake info node, or wrong proxy port.'
    exit 2
} elseif ($aiFailed -gt 0 -and $coreOk -gt 0) {
    Write-Host '[NODE ISSUE] General Google works, but cloudcode-pa failed (000).' -ForegroundColor Yellow
    Write-Host '             Your proxy injection works; the selected node has trouble reaching Google AI upstream. Switch node.'
    exit 3
} elseif ($slowAi -gt 0) {
    Write-Host '[SLOW] All domains reachable, but cloudcode-pa TLS handshake > 1.0s.' -ForegroundColor Yellow
    Write-Host '       Consider switching GLOBAL / proxy-group to a lower-latency node for Google AI.'
    exit 0
} else {
    Write-Host '[OK] Proxy port, active node, and all Antigravity/Google endpoints look healthy.' -ForegroundColor Green
    exit 0
}
