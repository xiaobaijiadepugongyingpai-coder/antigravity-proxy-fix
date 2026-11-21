param(
    [switch]$AddDebugPort
)

$ErrorActionPreference = 'Stop'

# ============================================================
#  Repoint Antigravity shortcuts to the proxy launcher
#
#  Why: Antigravity's Go core only reads HTTP_PROXY/HTTPS_PROXY
#  environment variables. It ignores the Windows system proxy.
#  The launcher injects those variables; this script makes the
#  shortcuts call the launcher instead of the raw exe.
#
#  Existing shortcut Arguments (such as AntigravityPulse's
#  --remote-debugging-port=0 --remote-debugging-address=127.0.0.1)
#  are preserved verbatim. Pass -AddDebugPort to ensure those
#  loopback debug flags are present on all shortcuts.
#
#  NOTE: this file is intentionally pure ASCII (English only).
#  Non-ASCII text in a .ps1 without a BOM is misread by
#  Windows PowerShell 5.1 under a non-UTF8 ANSI code page,
#  which breaks parsing. Keep it ASCII.
# ============================================================

function Merge-DebugArguments([string]$existingArgs) {
    $text = if ($null -eq $existingArgs) { '' } else { $existingArgs.Trim() }
    $tokens = @()
    if ($text -ne '') {
        $rxMatches = [regex]::Matches($text, '"[^"]*"|\S+')
        foreach ($m in $rxMatches) {
            $tokens += $m.Value
        }
    }

    $hasPort = $false
    $hasAddr = $false
    $ddIndex = -1
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $clean = $tokens[$i].Trim('"', "'")
        if ($clean -eq '--' -and $ddIndex -lt 0) {
            $ddIndex = $i
        }
        if ($clean -eq '--remote-debugging-port' -or $clean.StartsWith('--remote-debugging-port=')) {
            $hasPort = $true
        }
        if ($clean -eq '--remote-debugging-address' -or $clean.StartsWith('--remote-debugging-address=')) {
            $hasAddr = $true
        }
    }

    $added = @()
    if (-not $hasPort) { $added += '--remote-debugging-port=0' }
    if (-not $hasAddr) { $added += '--remote-debugging-address=127.0.0.1' }
    if ($added.Count -eq 0) {
        return $text
    }

    if ($ddIndex -ge 0) {
        $before = if ($ddIndex -gt 0) { $tokens[0..($ddIndex - 1)] } else { @() }
        $after  = $tokens[$ddIndex..($tokens.Count - 1)]
        return ((@($before) + @($added) + @($after)) -join ' ').Trim()
    }
    return ((@($tokens) + @($added)) -join ' ').Trim()
}

$launcher = Join-Path $env:USERPROFILE '.agy-shim\Antigravity-Proxy.cmd'
$exe      = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'

if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Warning "launcher not found: $launcher"
    Write-Warning 'Place Antigravity-Proxy.cmd in a .agy-shim folder under your user profile first.'
    exit 1
}

# A missing Antigravity.exe is NOT fatal. The exe is only used to copy the
# original icon; the repair itself is about the launcher. self-heal also
# proceeds without it, so refusing here would make the two scripts disagree
# on the same machine state.
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Warning "Antigravity.exe not found: $exe (continuing without a custom icon)"
}

# The desktop shortcut may have been moved into a subfolder; try both.
$targets = @(
    (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Agent\Antigravity.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk')
)

$sh = New-Object -ComObject WScript.Shell
$expectedArgsByTarget = @{}

foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host ("skip (not found): " + $t)
        continue
    }

    # Do not let one unwritable shortcut abort the remaining ones.
    # The verify pass below is what decides success or failure.
    try {
        $s = $sh.CreateShortcut($t)
        $preservedArgs = if ($null -eq $s.Arguments) { '' } else { [string]$s.Arguments }
        if ($AddDebugPort) {
            $preservedArgs = Merge-DebugArguments $preservedArgs
        }
        $expectedArgsByTarget[$t] = $preservedArgs

        $s.TargetPath       = $launcher
        $s.Arguments        = $preservedArgs
        $s.WorkingDirectory = Split-Path $launcher
        if (Test-Path -LiteralPath $exe) { $s.IconLocation = $exe + ',0' }  # keep the original icon
        $s.WindowStyle      = 7              # minimized, hide the cmd flash
        $s.Description      = 'Antigravity (with proxy)'
        $s.Save()
        if ($preservedArgs -ne '') {
            Write-Host ("updated: " + $t + "  (args: " + $preservedArgs + ")")
        } else {
            Write-Host ("updated: " + $t)
        }
    } catch {
        Write-Host ("update FAILED: " + $t)
        Write-Host ("               " + $_.Exception.Message)
        Write-Host ("               hint: file may be read-only; try: attrib -R `"" + $t + "`"")
    }
}

# Always verify afterwards: bulk edits are the easiest place to miss one.
Write-Host ''
Write-Host '--- verify ---'
$bad = 0
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) { continue }
    $target = $null
    $argsAfter = ''
    try {
        $chk = $sh.CreateShortcut($t)
        $target = $chk.TargetPath
        $argsAfter = if ($null -eq $chk.Arguments) { '' } else { [string]$chk.Arguments }
    } catch {
        $target = $null
    }
    $expectedArgs = if ($expectedArgsByTarget.ContainsKey($t)) { $expectedArgsByTarget[$t] } else { '' }

    # Compare against the exact launcher path AND confirm arguments survived.
    if ($target -eq $launcher -and $argsAfter -eq $expectedArgs) {
        if ($argsAfter -ne '') {
            Write-Host ("  OK   " + $t + "  [args: " + $argsAfter + "]")
        } else {
            Write-Host ("  OK   " + $t)
        }
    } else {
        if ($null -eq $target) {
            Write-Host ("  FAIL " + $t + " -> (unreadable)") -ForegroundColor Red
        } elseif ($target -ne $launcher) {
            Write-Host ("  FAIL " + $t + " -> " + $target) -ForegroundColor Red
        } else {
            Write-Host ("  FAIL " + $t + " -> args mismatch: got '" + $argsAfter + "', expected '" + $expectedArgs + "'") -ForegroundColor Red
        }
        $bad++
    }
}

if ($bad -gt 0) {
    Write-Warning ("$bad shortcut(s) still point at the raw exe")
    exit 1
}

Write-Host 'All shortcuts now point to the launcher.' -ForegroundColor Green
