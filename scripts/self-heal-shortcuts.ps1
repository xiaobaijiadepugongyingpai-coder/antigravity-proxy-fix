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
#  a shortcut when TargetPath does NOT already point at the launcher,
#  so a healthy install produces no disk writes and no popups.
#
#  Existing shortcut Arguments (such as --remote-debugging-port=0
#  --remote-debugging-address=127.0.0.1 used by Antigrative Dashboard
#  / antigravity-pulse) are ALWAYS preserved, never wiped.
#
#  Exit codes:
#    0 = everything already fine (or every needed fix verified OK)
#    1 = launcher missing
#    2 = one or more shortcuts could not be fixed (see output)
#
#  IMPORTANT: this script does not trust $s.Save() and does not
#  report success just because it printed a line. After every save
#  it reads the shortcut back and compares TargetPath and Arguments
#  against expected values.
#
#  NOTE: this file is intentionally pure ASCII (English only).
#  Non-ASCII text in a .ps1 without a BOM is misread by
#  Windows PowerShell 5.1 under a non-UTF8 ANSI code page,
#  which throws "TerminatorExpectedAtEndOfString".
# ============================================================

$shimDir      = Join-Path $env:USERPROFILE '.agy-shim'
$exeLauncher  = Join-Path $shimDir 'AntigravityProxy.exe'
$cmdLauncher  = Join-Path $shimDir 'Antigravity-Proxy.cmd'
$exe          = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'

if (Test-Path -LiteralPath $exeLauncher) {
    $launcher = $exeLauncher
} else {
    $launcher = $cmdLauncher
}

if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Host ("[self-heal] launcher missing: " + $launcher)
    exit 1
}

$isExeLauncher = ([IO.Path]::GetExtension($launcher).ToLowerInvariant() -eq '.exe')
$startMenuLnk  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk'

function Set-ShortcutAumid([string]$lnkPath, [string]$aumid) {
    if (-not ('AgSelfHealAumid' -as [type])) {
        $cs = @'
using System;
using System.Runtime.InteropServices;

public static class AgSelfHealAumid {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink {}

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
    private interface IPersistFile {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PROPERTYKEY {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pwszVal;
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    private interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        void Commit();
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT pvar);

    public static void Set(string path, string aumid) {
        object obj = new ShellLink();
        try {
            IPersistFile pf = (IPersistFile)obj;
            pf.Load(path, 2);
            IPropertyStore ps = (IPropertyStore)obj;
            PROPERTYKEY key = new PROPERTYKEY {
                fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
                pid = 5
            };
            PROPVARIANT pv = new PROPVARIANT {
                vt = 31,
                pwszVal = Marshal.StringToCoTaskMemUni(aumid)
            };
            try {
                ps.SetValue(ref key, ref pv);
                ps.Commit();
                pf.Save(path, true);
            } finally {
                PropVariantClear(ref pv);
            }
        } finally {
            Marshal.FinalReleaseComObject(obj);
        }
    }
}
'@
        Add-Type -TypeDefinition $cs -ErrorAction Stop
    }
    [AgSelfHealAumid]::Set($lnkPath, $aumid)
}

$targets = @(
    (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Agent\Antigravity.lnk'),
    $startMenuLnk,
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Antigravity.lnk')
)

$sh = New-Object -ComObject WScript.Shell

# Detect whether any existing shortcut already uses loopback CDP debug flags
# (e.g. for Antigrative Dashboard / antigravity-pulse), so that if Squirrel
# wiped a Start Menu shortcut's arguments during an update, we restore them.
$peerHasDebugPort = $false
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) { continue }
    try {
        $peerArgs = [string]($sh.CreateShortcut($t).Arguments)
        if ($peerArgs -match '--remote-debugging-port(=|\s|$)' -and
            $peerArgs -match '--remote-debugging-address=127\.0\.0\.1(\s|$)') {
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

    # Healthy means: exact launcher target. Extra arguments (such as plugin
    # debug flags) are valid and MUST NOT be treated as errors or cleared.
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
        $s.WindowStyle      = if ($isExeLauncher) { 1 } else { 7 }
        $s.Description      = 'Antigravity (with proxy)'
        $s.Save()
        if ($t.Equals($startMenuLnk, [StringComparison]::OrdinalIgnoreCase)) {
            try { Set-ShortcutAumid $t 'electron.app.Antigravity' } catch { }
        }
    } catch {
        $saveError = $_.Exception.Message
    }

    # Read back and verify both TargetPath and Arguments.
    $after = $null
    $afterArgs = $null
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

    # The Startup shim (self-heal-shortcuts.vbs) runs this script with a
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
