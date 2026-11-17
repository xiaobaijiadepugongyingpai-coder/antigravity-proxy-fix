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
#    0 = everything already fine (or every needed fix verified OK)
#    1 = launcher missing
#    2 = one or more shortcuts could not be fixed (see output)
#
#  IMPORTANT: this script does not trust $s.Save() and does not
#  report success just because it printed a line. After every save
#  it reads the shortcut back and compares TargetPath against the
#  expected launcher. A save that throws, silently no-ops, or gets
#  reverted is reported as a failure -- never as a success.
#  (Earlier versions printed "fixed N" and exited 0 even when the
#  underlying save failed with UnauthorizedAccessException.)
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
$failed = 0

foreach ($t in $targets) {
    if (-not (Test-Path $t)) { continue }

    # Read current state. A shortcut that already resolves to the
    # launcher needs no write at all (keeps this script idempotent).
    $current = $null
    try {
        $current = $sh.CreateShortcut($t).TargetPath
    } catch {
        Write-Host ("[self-heal] FAILED to read: " + $t)
        Write-Host ("             " + $_.Exception.Message)
        $failed++
        continue
    }

    # Already correct? Compare against the exact launcher path.
    # Do NOT test for '*.cmd' here: a shortcut pointing at some OTHER
    # .cmd is still broken, and treating it as healthy would make this
    # script skip the fix and still exit 0.
    if ($current -eq $launcher) { continue }

    # Attempt the write. Catch everything: an unwritable lnk must be
    # reported, not swallowed.
    $saveError = $null
    try {
        $s = $sh.CreateShortcut($t)
        $s.TargetPath       = $launcher
        $s.Arguments        = ''
        $s.WorkingDirectory = Split-Path $launcher
        if (Test-Path $exe) { $s.IconLocation = $exe + ',0' }
        $s.WindowStyle      = 7
        $s.Description      = 'Antigravity (with proxy)'
        $s.Save()
    } catch {
        $saveError = $_.Exception.Message
    }

    # Read back and verify. This is the part the old version lacked:
    # without it, a failed save still printed "repointed" and counted
    # as fixed.
    $after = $null
    $afterArgs = $null
    try {
        $rb = $sh.CreateShortcut($t)
        $after = $rb.TargetPath
        $afterArgs = $rb.Arguments
    } catch {
        $after = $null
    }

    # A correct shortcut needs the right target AND no leftover arguments.
    # Stale arguments (e.g. from a previous launcher variant) would be
    # passed to the launcher and can break startup, so they count as a
    # failed repair rather than a silent partial success.
    if ($after -eq $launcher -and (-not $afterArgs -or $afterArgs.Trim() -eq '')) {
        $fixed++
        Write-Host ("[self-heal] repointed: " + $t)
    } else {
        $failed++
        Write-Host ("[self-heal] FAILED to repoint: " + $t)
        if ($saveError) {
            Write-Host ("             save error: " + $saveError)
        }
        if ($null -eq $after) {
            Write-Host ("             could not read the shortcut back")
        } elseif ($after -ne $launcher) {
            Write-Host ("             still points at: " + $after)
        } else {
            Write-Host ("             target is correct but arguments were not cleared: '" + $afterArgs + "'")
        }
        Write-Host ("             hint: the file may be read-only or locked")
        Write-Host ("             try: attrib -R `"" + $t + "`"")
    }
}

if ($fixed -gt 0) {
    Write-Host ("[self-heal] fixed " + $fixed + " shortcut(s) after an app update.")
}

if ($failed -gt 0) {
    Write-Host ("[self-heal] " + $failed + " shortcut(s) could NOT be fixed.")
    exit 2
}

exit 0
