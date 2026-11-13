$ErrorActionPreference = 'Continue'

# ============================================================
#  Self-heal: repoint the Antigravity shortcuts if an app update
#  reset them back to the raw exe.
#
#  Why: Antigravity uses the Squirrel/Electron auto-updater, which
#  recreates the Start Menu shortcut on every install/update. That
#  silently reverts the shortcut to the unproxied exe, and the app
#  then fails again exactly as before.
#
#  This script is safe to run any number of times. It only rewrites
#  a shortcut when it does NOT already point at the launcher, so a
#  healthy install produces no disk writes and no popups.
#
#  Exit codes:
#    0 = everything already fine (or fixed successfully)
#    1 = launcher missing / could not fix
#
#  NOTE: this file is intentionally pure ASCII (English only).
#  Non-ASCII text in a .ps1 without a BOM is misread by
#  Windows PowerShell 5.1 under a non-UTF8 ANSI code page,
#  which throws "TerminatorExpectedAtEndOfString".
# ============================================================

$launcher = Join-Path $env:USERPROFILE '.agy-shim\Antigravity-Proxy.cmd'
$exe      = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'

if (-not (Test-Path $launcher)) {
    Write-Host ("[self-heal] launcher missing: " + $launcher)
    exit 1
}

$targets = @(
    (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Agent\Antigravity.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk')
)

$sh = New-Object -ComObject WScript.Shell
$fixed = 0

foreach ($t in $targets) {
    if (-not (Test-Path $t)) { continue }

    $s = $sh.CreateShortcut($t)

    # Already correct? Then do nothing at all (no writes, no noise).
    if ($s.TargetPath -like '*.cmd') { continue }

    $s.TargetPath       = $launcher
    $s.Arguments        = ''
    $s.WorkingDirectory = Split-Path $launcher
    if (Test-Path $exe) { $s.IconLocation = $exe + ',0' }
    $s.WindowStyle      = 7
    $s.Description      = 'Antigravity (with proxy)'
    $s.Save()

    $fixed++
    Write-Host ("[self-heal] repointed: " + $t)
}

if ($fixed -gt 0) {
    Write-Host ("[self-heal] fixed " + $fixed + " shortcut(s) after an app update.")
}

exit 0
