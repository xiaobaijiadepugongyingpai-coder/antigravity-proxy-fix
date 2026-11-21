param(
    [switch]$Purge,
    [switch]$DryRun,
    [string]$ShimHome = (Join-Path $env:USERPROFILE '.agy-shim'),
    [string]$CliShimDir = (Join-Path $env:LOCALAPPDATA 'agy\shim'),
    [string]$StartupVbs = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\self-heal-shortcuts.vbs'),
    [string]$RealExe = (Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'),
    [string[]]$ShortcutPaths = @(),
    [switch]$SkipPath
)

$ErrorActionPreference = 'Stop'

# ============================================================
#  One-click uninstaller for Antigravity Proxy Fix (Windows)
#
#  Reverts changes safely and leaves global settings untouched:
#    1. Unlocks Read-Only (+R) if set on Start Menu shortcut and
#       restores proxy shortcuts back to Antigravity.exe while
#       preserving Arguments (e.g. --remote-debugging-port=0) and
#       Start Menu AppUserModelID (electron.app.Antigravity).
#    2. Removes %LOCALAPPDATA%\agy\shim from HKCU\Environment\Path
#       (preserving ExpandString) and broadcasts WM_SETTINGCHANGE.
#    3. Removes the Startup self-heal VBS hook.
#    4. Removes deployed launcher/shim/self-heal files (keeps
#       proxy.conf by default; pass -Purge to delete everything).
#    5. Never removes real Antigravity/agy or alters ExecutionPolicy.
#
#  NOTE: this file is intentionally pure ASCII (English only).
# ============================================================

function Set-ShortcutAumid([string]$lnkPath, [string]$aumid) {
    if (-not ('AgUninstallAumid' -as [type])) {
        $cs = @'
using System;
using System.Runtime.InteropServices;

public static class AgUninstallAumid {
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
    [AgUninstallAumid]::Set($lnkPath, $aumid)
}

function Send-EnvChangeBroadcast {
    try {
        if (-not ('Win32.AgEnvNotify' -as [type])) {
            $sig = @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeoutW(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
            Add-Type -Namespace Win32 -Name AgEnvNotify -MemberDefinition $sig -ErrorAction Stop | Out-Null
        }
        $res = [UIntPtr]::Zero
        [Win32.AgEnvNotify]::SendMessageTimeoutW([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$res) | Out-Null
    } catch { }
}

function Normalize-DirPrefix([string]$path) {
    if (-not $path) { return '' }
    try {
        return ([IO.Path]::GetFullPath($path)).TrimEnd('\', '/') + '\'
    } catch {
        return $path.TrimEnd('\', '/') + '\'
    }
}

function Test-ManagedTarget([string]$targetPath, [string]$shimPrefix) {
    if (-not $targetPath) { return $false }
    $fileName = [IO.Path]::GetFileName($targetPath)
    if ($fileName.Equals('AntigravityProxy.exe', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($shimPrefix) {
        try {
            $full = [IO.Path]::GetFullPath($targetPath)
            if ($full.StartsWith($shimPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        } catch { }
    }
    return $false
}

function Remove-FileIfPresent([string]$path, [ref]$removedCount) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    if ($DryRun) {
        Write-Host ('  [dry-run] would remove: ' + $path) -ForegroundColor Cyan
    } else {
        Remove-Item -LiteralPath $path -Force
        Write-Host ('  removed: ' + $path)
    }
    $removedCount.Value++
}

function Remove-EmptyDirIfPresent([string]$dirPath, [ref]$removedCount) {
    if (-not $dirPath -or -not (Test-Path -LiteralPath $dirPath)) { return }
    $remaining = @(Get-ChildItem -LiteralPath $dirPath -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        if ($DryRun) {
            Write-Host ('  [dry-run] would remove empty dir: ' + $dirPath) -ForegroundColor Cyan
        } else {
            Remove-Item -LiteralPath $dirPath -Force
            Write-Host ('  removed empty dir: ' + $dirPath)
        }
        $removedCount.Value++
    }
}

$shimHomePrefix = Normalize-DirPrefix $ShimHome
$startMenuLnk   = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity.lnk'

if ($ShortcutPaths.Count -eq 0) {
    $targets = @(
        (Join-Path $env:USERPROFILE 'Desktop\Antigravity.lnk'),
        (Join-Path $env:USERPROFILE 'Desktop\Agent\Antigravity.lnk'),
        $startMenuLnk,
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Antigravity.lnk')
    )
} else {
    $targets = @()
    foreach ($sp in $ShortcutPaths) {
        if ($sp) {
            foreach ($part in ($sp -split ';')) {
                if ($part.Trim() -ne '') { $targets += $part.Trim() }
            }
        }
    }
}

$restoredShortcuts = 0
$failedShortcuts   = 0
$pathUpdated       = $false
$removedItems      = 0

Write-Host '=== 1. Restore Antigravity shortcuts ===' -ForegroundColor Cyan
$sh = New-Object -ComObject WScript.Shell
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host ('  skip (not found): ' + $t) -ForegroundColor DarkGray
        continue
    }

    $curTarget = ''
    $curArgs   = ''
    try {
        $cur = $sh.CreateShortcut($t)
        $curTarget = if ($null -eq $cur.TargetPath) { '' } else { [string]$cur.TargetPath }
        $curArgs   = if ($null -eq $cur.Arguments) { '' } else { [string]$cur.Arguments }
    } catch {
        Write-Host ('  FAIL to read: ' + $t + ' -> ' + $_.Exception.Message) -ForegroundColor Red
        $failedShortcuts++
        continue
    }

    if (-not (Test-ManagedTarget $curTarget $shimHomePrefix)) {
        Write-Host ('  skip (not managed): ' + $t + ' -> ' + $curTarget) -ForegroundColor DarkGray
        continue
    }

    $item = Get-Item -LiteralPath $t
    $wasReadOnly = [bool]($item.Attributes -band [IO.FileAttributes]::ReadOnly)
    $isStartMenu = $t.Equals($startMenuLnk, [StringComparison]::OrdinalIgnoreCase) -or
                   $t.EndsWith('\Start Menu\Programs\Antigravity.lnk', [StringComparison]::OrdinalIgnoreCase)

    if ($DryRun) {
        $note = if ($wasReadOnly) { ' (would clear +R)' } else { '' }
        Write-Host ('  [dry-run] would restore: ' + $t + ' -> ' + $RealExe + $note) -ForegroundColor Cyan
        if ($curArgs -ne '') {
            Write-Host ('            preserving args: ' + $curArgs) -ForegroundColor Cyan
        }
        $restoredShortcuts++
        continue
    }

    try {
        if ($wasReadOnly) {
            $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }

        $s = $sh.CreateShortcut($t)
        $s.TargetPath       = $RealExe
        $s.Arguments        = $curArgs
        $s.WorkingDirectory = Split-Path -Parent $RealExe
        if (Test-Path -LiteralPath $RealExe) { $s.IconLocation = $RealExe + ',0' }
        $s.WindowStyle      = 1
        $s.Description      = 'Antigravity'
        $s.Save()

        if ($isStartMenu) {
            try { Set-ShortcutAumid $t 'electron.app.Antigravity' } catch { }
        }

        $rb = $sh.CreateShortcut($t)
        $rbTarget = if ($null -eq $rb.TargetPath) { '' } else { [string]$rb.TargetPath }
        $rbArgs   = if ($null -eq $rb.Arguments) { '' } else { [string]$rb.Arguments }
        if ($rbTarget -ne $RealExe -or $rbArgs -ne $curArgs) {
            throw ("verification mismatch: target='$rbTarget' args='$rbArgs'")
        }

        $msg = '  restored: ' + $t
        if ($wasReadOnly) { $msg += '  [cleared +R]' }
        if ($curArgs -ne '') { $msg += '  (args preserved: ' + $curArgs + ')' }
        Write-Host $msg -ForegroundColor Green
        $restoredShortcuts++
    } catch {
        Write-Host ('  FAIL to restore: ' + $t + ' -> ' + $_.Exception.Message) -ForegroundColor Red
        $failedShortcuts++
    }
}

Write-Host ''
Write-Host '=== 2. Clean user PATH (HKCU\Environment\Path) ===' -ForegroundColor Cyan
if ($SkipPath) {
    Write-Host '  skipped (-SkipPath specified)' -ForegroundColor DarkGray
} else {
    $regKey = Get-Item 'HKCU:\Environment'
    $rawPath = $regKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $parts = @($rawPath -split ';' | Where-Object { $_.Trim() -ne '' })
    $defaultToken = '%LOCALAPPDATA%\agy\shim'
    $expandedCli  = [Environment]::ExpandEnvironmentVariables($CliShimDir).TrimEnd('\', '/')
    $normCli      = $CliShimDir.Trim().TrimEnd('\', '/')

    $kept = New-Object System.Collections.Generic.List[string]
    $removedEntries = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        $trimmed = $p.Trim()
        $clean   = $trimmed.TrimEnd('\', '/')
        $exp     = [Environment]::ExpandEnvironmentVariables($trimmed).TrimEnd('\', '/')
        if ($clean.Equals($defaultToken, [StringComparison]::OrdinalIgnoreCase) -or
            $clean.Equals($normCli, [StringComparison]::OrdinalIgnoreCase) -or
            $exp.Equals($expandedCli, [StringComparison]::OrdinalIgnoreCase)) {
            $removedEntries.Add($trimmed)
        } else {
            $kept.Add($trimmed)
        }
    }

    if ($removedEntries.Count -eq 0) {
        Write-Host '  not present in HKCU\Environment\Path (nothing to remove)' -ForegroundColor DarkGray
    } elseif ($DryRun) {
        Write-Host ('  [dry-run] would remove from HKCU\Environment\Path: ' + ($removedEntries -join ', ')) -ForegroundColor Cyan
        $pathUpdated = $true
    } else {
        $newPath = $kept.ToArray() -join ';'
        [Microsoft.Win32.Registry]::SetValue(
            'HKEY_CURRENT_USER\Environment', 'Path', $newPath,
            [Microsoft.Win32.RegistryValueKind]::ExpandString)
        Send-EnvChangeBroadcast
        Write-Host ('  removed from PATH (ExpandString preserved): ' + ($removedEntries -join ', ')) -ForegroundColor Green
        $pathUpdated = $true
    }
}

Write-Host ''
Write-Host '=== 3. Remove startup hook & deployed files ===' -ForegroundColor Cyan
Remove-FileIfPresent $StartupVbs ([ref]$removedItems)

$filesToRemove = @(
    (Join-Path $ShimHome 'AntigravityProxy.exe'),
    (Join-Path $ShimHome 'self-heal-shortcuts.ps1'),
    (Join-Path $ShimHome 'self-heal.log'),
    (Join-Path $CliShimDir 'agy.exe')
)
# Also remove legacy batch launcher if still present from an earlier install.
$legacyFiles = @(Get-ChildItem -LiteralPath $ShimHome -Filter '*.cmd' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
foreach ($lf in $legacyFiles) { $filesToRemove += $lf }

foreach ($f in $filesToRemove) {
    Remove-FileIfPresent $f ([ref]$removedItems)
}

$confPath = Join-Path $ShimHome 'proxy.conf'
if ($Purge) {
    Remove-FileIfPresent $confPath ([ref]$removedItems)
    Remove-EmptyDirIfPresent $CliShimDir ([ref]$removedItems)
    Remove-EmptyDirIfPresent $ShimHome ([ref]$removedItems)
} elseif (Test-Path -LiteralPath $confPath) {
    Write-Host ('  kept config: ' + $confPath + '  (pass -Purge to remove)') -ForegroundColor DarkGray
}

if ($removedItems -eq 0 -and $restoredShortcuts -eq 0 -and -not $pathUpdated -and $failedShortcuts -eq 0) {
    Write-Host '  nothing to uninstall.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '=== 4. Summary ===' -ForegroundColor Cyan
Write-Host ('  shortcuts restored : ' + $restoredShortcuts)
Write-Host ('  shortcuts failed   : ' + $failedShortcuts)
Write-Host ('  PATH updated       : ' + $pathUpdated)
Write-Host ('  files/dirs removed : ' + $removedItems)
if ($pathUpdated -and -not $DryRun) {
    Write-Host 'Open a NEW terminal for the restored PATH to take effect.' -ForegroundColor Yellow
}

if ($failedShortcuts -gt 0) {
    exit 1
}
exit 0
