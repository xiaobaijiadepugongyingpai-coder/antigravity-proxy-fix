param(
    [string]$LauncherPath = '',
    [switch]$AddDebugPort,
    [switch]$ProtectStartMenu,
    [switch]$UnlockStartMenu
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
#  Launcher preference:
#    1. Explicit -LauncherPath
#    2. %USERPROFILE%\.agy-shim\AntigravityProxy.exe (preferred:
#       no console flash, verbatim arg forwarding, recognized by
#       plugins such as Antigrative Dashboard / antigravity-pulse)
#    3. %USERPROFILE%\.agy-shim\Antigravity-Proxy.cmd (fallback)
#
#  Existing shortcut Arguments (e.g. --remote-debugging-port=0
#  --remote-debugging-address=127.0.0.1) are ALWAYS preserved.
#
#  Start Menu protection:
#    Electron's Windows Toast Notification handler rewrites
#    Start Menu\Programs\Antigravity.lnk back to Antigravity.exe
#    (wiping Arguments) whenever a desktop notification fires.
#    This script restores System.AppUserModel.ID=electron.app.Antigravity
#    on the Start Menu shortcut, and with -ProtectStartMenu sets
#    Read-Only (+R) so Electron cannot overwrite it at runtime.
#
#  NOTE: this file is intentionally pure ASCII (English only).
#  Non-ASCII text in a .ps1 without a BOM is misread by
#  Windows PowerShell 5.1 under a non-UTF8 ANSI code page,
#  which breaks parsing. Keep it ASCII.
# ============================================================

$shimDir      = Join-Path $env:USERPROFILE '.agy-shim'
$exeLauncher  = Join-Path $shimDir 'AntigravityProxy.exe'
$cmdLauncher  = Join-Path $shimDir 'Antigravity-Proxy.cmd'
$exe          = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'
$startMenuLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk'

if ($LauncherPath.Trim() -ne '') {
    $launcher = $LauncherPath.Trim()
} elseif (Test-Path -LiteralPath $exeLauncher) {
    $launcher = $exeLauncher
} else {
    $launcher = $cmdLauncher
}

if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Warning "launcher not found: $launcher"
    Write-Warning 'Run scripts\build-desktop-launcher.ps1 (for AntigravityProxy.exe) or copy Antigravity-Proxy.cmd to %USERPROFILE%\.agy-shim\ first.'
    exit 1
}

$isExeLauncher = ([IO.Path]::GetExtension($launcher).ToLowerInvariant() -eq '.exe')
Write-Host ('Using launcher: ' + $launcher)

# A missing Antigravity.exe is NOT fatal. The exe is only used to copy the
# original icon; the repair itself is about the launcher. self-heal also
# proceeds without it, so refusing here would make the two scripts disagree
# on the same machine state.
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Warning "Antigravity.exe not found: $exe (continuing without a custom icon)"
}

function Set-ShortcutAumid([string]$lnkPath, [string]$aumid) {
    if (-not ('AgShortcutAumid' -as [type])) {
        $cs = @'
using System;
using System.Runtime.InteropServices;

public static class AgShortcutAumid {
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
    [AgShortcutAumid]::Set($lnkPath, $aumid)
}

function Merge-DebugArguments([string]$existingArgs) {
    $text = if ($null -eq $existingArgs) { '' } else { $existingArgs.Trim() }
    $tokens = @()
    if ($text -ne '') {
        $matches = [regex]::Matches($text, '"[^"]*"|\S+')
        foreach ($m in $matches) {
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

# The desktop shortcut may have been moved into a subfolder; also check TaskBar pin.
$targets = @(
    (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Agent\Antigravity.lnk'),
    $startMenuLnk,
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Antigravity.lnk')
)

$sh = New-Object -ComObject WScript.Shell
$expectedArgsByTarget = @{}

foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host ("skip (not found): " + $t)
        continue
    }

    $isStartMenu = ($t.Equals($startMenuLnk, [StringComparison]::OrdinalIgnoreCase))
    $wasReadOnly = $false

    # Do not let one unwritable shortcut abort the remaining ones.
    # The verify pass below is what decides success or failure.
    try {
        $item = Get-Item -LiteralPath $t
        $wasReadOnly = [bool]($item.Attributes -band [IO.FileAttributes]::ReadOnly)
        if ($wasReadOnly -and ($isStartMenu -or $UnlockStartMenu)) {
            $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }

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
        $s.WindowStyle      = if ($isExeLauncher) { 1 } else { 7 }          # hide cmd flash only for .cmd
        $s.Description      = 'Antigravity (with proxy)'
        $s.Save()

        if ($isStartMenu) {
            # Restore Electron's AppUserModelID so Windows Toast notifications keep working.
            try { Set-ShortcutAumid $t 'electron.app.Antigravity' } catch { }

            $shouldProtect = $ProtectStartMenu -or ($wasReadOnly -and -not $UnlockStartMenu)
            if ($shouldProtect) {
                $item2 = Get-Item -LiteralPath $t
                $item2.Attributes = $item2.Attributes -bor [IO.FileAttributes]::ReadOnly
            }
        }

        $suffix = ''
        if ($preservedArgs -ne '') { $suffix += "  (args: $preservedArgs)" }
        if ($isStartMenu -and ((Get-Item -LiteralPath $t).Attributes -band [IO.FileAttributes]::ReadOnly)) {
            $suffix += '  [protected +R]'
        }
        Write-Host ("updated: " + $t + $suffix)
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
    $argsAfter = $null
    try {
        $chk = $sh.CreateShortcut($t)
        $target = $chk.TargetPath
        $argsAfter = if ($null -eq $chk.Arguments) { '' } else { [string]$chk.Arguments }
    } catch {
        $target = $null
    }
    $expectedArgs = if ($expectedArgsByTarget.ContainsKey($t)) { $expectedArgsByTarget[$t] } else { '' }

    # Compare against the exact launcher path AND verify preserved arguments survived.
    if ($target -eq $launcher -and $argsAfter -eq $expectedArgs) {
        $extra = ''
        if ($argsAfter -ne '') { $extra += "  [args: $argsAfter]" }
        if ((Get-Item -LiteralPath $t).Attributes -band [IO.FileAttributes]::ReadOnly) { $extra += '  [+R]' }
        Write-Host ("  OK   " + $t + $extra)
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
    Write-Warning ("$bad shortcut(s) failed verification")
    exit 1
}

Write-Host 'All shortcuts now point to the launcher.' -ForegroundColor Green
