param(
    [string]$OutputPath = (Join-Path $env:LOCALAPPDATA 'agy\shim\agy.exe'),
    [switch]$AddToPath
)

$ErrorActionPreference = 'Stop'

# ============================================================
#  Build agy.exe CLI shim using Windows built-in csc.exe
#
#  No MinGW-w64 required: compiles src\AgyShim.cs with the
#  .NET Framework 4 compiler built into Windows 10/11.
#
#  NOTE: this file is intentionally pure ASCII (English only).
# ============================================================

$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repoRoot 'src\AgyShim.cs'
$common = Join-Path $repoRoot 'src\ProxyCommon.cs'

if (-not (Test-Path -LiteralPath $source)) {
    Write-Error "Source file not found: $source"
    exit 1
}
if (-not (Test-Path -LiteralPath $common)) {
    Write-Error "Shared source file not found: $common"
    exit 1
}

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)

$csc = $null
foreach ($c in $cscCandidates) {
    if (Test-Path -LiteralPath $c) {
        $csc = $c
        break
    }
}

if (-not $csc) {
    Write-Error 'Built-in .NET Framework 4 csc.exe was not found under Windows\Microsoft.NET.'
    exit 1
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

Write-Host ('Compiling with: ' + $csc)
& $csc /nologo /target:exe /optimize+ /warn:4 "/out:$OutputPath" $source $common
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
    Write-Error ('Compilation failed with exit code ' + $LASTEXITCODE)
    exit 1
}

$ver = & $OutputPath --version
Write-Host ('Built: ' + $OutputPath + ' -> ' + $ver) -ForegroundColor Green

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

if ($AddToPath) {
    $regKey = Get-Item 'HKCU:\Environment'
    $raw = $regKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $parts = @($raw -split ';' | Where-Object { $_.Trim() -ne '' })
    $token = if ($outDir -eq (Join-Path $env:LOCALAPPDATA 'agy\shim')) { '%LOCALAPPDATA%\agy\shim' } else { $outDir }
    $filtered = @($parts | Where-Object { $_.Trim() -ne $token -and $_.Trim() -ne $outDir })
    $newPath = (@($token) + $filtered) -join ';'
    [Microsoft.Win32.Registry]::SetValue(
        'HKEY_CURRENT_USER\Environment', 'Path', $newPath,
        [Microsoft.Win32.RegistryValueKind]::ExpandString)
    Send-EnvChangeBroadcast
    Write-Host ('Prepended to HKCU\Environment\Path (ExpandString) and broadcast WM_SETTINGCHANGE: ' + $token) -ForegroundColor Green
    Write-Host 'Open a NEW terminal for the updated PATH to take effect (or restart an IDE/terminal launched earlier).'
}
