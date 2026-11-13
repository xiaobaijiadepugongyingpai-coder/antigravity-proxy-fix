$ErrorActionPreference = 'Stop'

# ============================================================
#  Repoint Antigravity shortcuts to the proxy launcher
#
#  Why: Antigravity's Go core only reads HTTP_PROXY/HTTPS_PROXY
#  environment variables. It ignores the Windows system proxy.
#  The launcher injects those variables; this script makes the
#  shortcuts call the launcher instead of the raw exe.
#
#  NOTE: this file is intentionally pure ASCII (English only).
#  Non-ASCII text in a .ps1 without a BOM is misread by
#  Windows PowerShell 5.1 under a non-UTF8 ANSI code page,
#  which breaks parsing. Keep it ASCII.
# ============================================================

$launcher = Join-Path $env:USERPROFILE '.agy-shim\Antigravity-Proxy.cmd'
$exe      = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'

if (-not (Test-Path $launcher)) {
    Write-Warning "launcher not found: $launcher"
    Write-Warning 'Place Antigravity-Proxy.cmd in a .agy-shim folder under your user profile first.'
    exit 1
}
if (-not (Test-Path $exe)) {
    Write-Warning "Antigravity.exe not found: $exe"
    exit 1
}

# The desktop shortcut may have been moved into a subfolder; try both.
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
    $s.IconLocation     = $exe + ',0'    # keep the original icon
    $s.WindowStyle      = 7              # minimized, hide the cmd flash
    $s.Description      = 'Antigravity (with proxy)'
    $s.Save()

    Write-Host ("updated: " + $t)
}

# Always verify afterwards: bulk edits are the easiest place to miss one.
Write-Host ''
Write-Host '--- verify ---'
$bad = 0
foreach ($t in $targets) {
    if (-not (Test-Path $t)) { continue }
    $target = $sh.CreateShortcut($t).TargetPath
    if ($target -like '*.cmd') {
        Write-Host ("  OK   " + $t)
    } else {
        Write-Host ("  FAIL " + $t + " -> " + $target) -ForegroundColor Red
        $bad++
    }
}

if ($bad -gt 0) {
    Write-Warning ("$bad shortcut(s) still point at the raw exe")
    exit 1
}

Write-Host 'All shortcuts now point to the launcher.' -ForegroundColor Green
