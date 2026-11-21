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
#  it reads the shortcut back and compares TargetPath and Arguments
#  against expected values. A save that throws, silently no-ops, or
#  gets reverted is reported as a failure -- never as a success.
#  (Earlier versions printed "fixed N" and exited 0 even when the
#  underlying save failed with UnauthorizedAccessException.)
#
#  Existing shortcut Arguments (such as AntigravityPulse's
#  --remote-debugging-port=0 --remote-debugging-address=127.0.0.1)
#  are ALWAYS preserved, never cleared. If an app update wiped a
#  Start Menu shortcut's arguments while a sibling shortcut still
#  carries them, self-heal restores them automatically.
#
#  NOTE: this file is intentionally pure ASCII (English only).
#  Non-ASCII text in a .ps1 without a BOM is misread by
#  Windows PowerShell 5.1 under a non-UTF8 ANSI code page,
#  which throws "TerminatorExpectedAtEndOfString".
# ============================================================

$launcher = Join-Path $env:USERPROFILE '.agy-shim\Antigravity-Proxy.cmd'
$exe      = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'

if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Host ("[self-heal] launcher missing: " + $launcher)
    exit 1
}

$targets = @(
    (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Agent\Antigravity.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk')
)

$sh = New-Object -ComObject WScript.Shell

# Detect whether any existing shortcut carries --remote-debugging-port=
# (e.g. set by AntigravityPulse), so that if Squirrel/Electron wiped a
# Start Menu shortcut's arguments on update, we restore them cleanly.
$peerHasDebugPort = $false
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) { continue }
    try {
        $peerArgs = [string]($sh.CreateShortcut($t).Arguments)
        if ($peerArgs -match '--remote-debugging-port=') {
            $peerHasDebugPort = $true
            break
        }
    } catch { }
}

$fixed = 0
$failed = 0

foreach ($t in $targets) {
    # -LiteralPath: a path containing [ or ] would otherwise be read as a
    # wildcard and the shortcut would be skipped as "not found".
    if (-not (Test-Path -LiteralPath $t)) { continue }

    # Read current state.
    $current = $null
    $currentArgs = ''
    try {
        $cur = $sh.CreateShortcut($t)
        $current = $cur.TargetPath
        $currentArgs = if ($null -eq $cur.Arguments) { '' } else { [string]$cur.Arguments }
    } catch {
        Write-Host ("[self-heal] FAILED to read: " + $t)
        Write-Host ("             " + $_.Exception.Message)
        $failed++
        continue
    }

    # Healthy means: exact launcher target. Do NOT test for '*.cmd' here:
    # a shortcut pointing at some OTHER .cmd is still broken. Valid plugin
    # arguments (such as --remote-debugging-port=0) MUST be preserved, not
    # treated as unhealthy or wiped.
    if ($current -eq $launcher) { continue }

    $desiredArgs = $currentArgs
    if ($desiredArgs.Trim() -eq '' -and $peerHasDebugPort) {
        $desiredArgs = '--remote-debugging-port=0 --remote-debugging-address=127.0.0.1'
    }

    # Attempt the write. Catch everything: an unwritable lnk must be
    # reported, not swallowed.
    $saveError = $null
    try {
        $s = $sh.CreateShortcut($t)
        $s.TargetPath       = $launcher
        $s.Arguments        = $desiredArgs
        $s.WorkingDirectory = Split-Path $launcher
        if (Test-Path -LiteralPath $exe) { $s.IconLocation = $exe + ',0' }
        $s.WindowStyle      = 7
        $s.Description      = 'Antigravity (with proxy)'
        $s.Save()
    } catch {
        $saveError = $_.Exception.Message
    }

    # Read back and verify both TargetPath and Arguments. This is the part
    # the old version lacked: without it, a failed save still printed
    # "repointed" and counted as fixed.
    $after = $null
    $afterArgs = ''
    try {
        $rb = $sh.CreateShortcut($t)
        $after = $rb.TargetPath
        $afterArgs = if ($null -eq $rb.Arguments) { '' } else { [string]$rb.Arguments }
    } catch {
        $after = $null
    }

    if ($after -eq $launcher -and $afterArgs -eq $desiredArgs) {
        $fixed++
        if ($desiredArgs -ne '') {
            Write-Host ("[self-heal] repointed: " + $t + "  (args: " + $desiredArgs + ")")
        } else {
            Write-Host ("[self-heal] repointed: " + $t)
        }
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
            Write-Host ("             target is correct but arguments mismatch: got '" + $afterArgs + "', expected '" + $desiredArgs + "'")
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

    # The Startup shim (antigravity-self-heal.vbs) runs this script with a
    # hidden window, does not wait for it, and discards the exit code. On
    # that path the messages above are invisible, so a failed repair would
    # otherwise leave no trace at all. Append a line to a log instead.
    # Only written on failure: a healthy run stays completely silent and
    # touches no disk, which is what keeps this safe to run at every logon.
    try {
        $logDir = Join-Path $env:USERPROFILE '.agy-shim'
        if (Test-Path -LiteralPath $logDir) {
            $logPath = Join-Path $logDir 'self-heal.log'
            $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $line = $stamp + '  FAILED: ' + $failed + ' shortcut(s) could not be fixed.'
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        }
    } catch {
        # Logging is best-effort; never let it change the outcome.
    }

    exit 2
}

exit 0
