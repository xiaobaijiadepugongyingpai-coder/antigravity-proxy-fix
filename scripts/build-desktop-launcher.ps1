param(
    [string]$OutputPath = (Join-Path $env:USERPROFILE '.agy-shim\AntigravityProxy.exe'),
    [string]$ProxyUrl = ''
)

$ErrorActionPreference = 'Stop'

# ============================================================
#  Build AntigravityProxy.exe using Windows built-in csc.exe
#
#  No MinGW or Visual Studio required: every Windows 10/11
#  install ships with .NET Framework 4 csc.exe.
#
#  NOTE: this file is intentionally pure ASCII (English only).
# ============================================================

$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repoRoot 'src\AntigravityProxy.cs'
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
& $csc /nologo /target:winexe /optimize+ /warn:4 "/out:$OutputPath" $source $common
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
    Write-Error ('Compilation failed with exit code ' + $LASTEXITCODE)
    exit 1
}

$ver = (Get-Item -LiteralPath $OutputPath).VersionInfo.FileVersion
Write-Host ('Built: ' + $OutputPath + ' (v' + $ver + ')') -ForegroundColor Green

# Manage optional proxy.conf alongside the launcher.
$confPath = Join-Path $outDir 'proxy.conf'
if ($ProxyUrl.Trim() -ne '') {
    $lines = @(
        '# Proxy address for AntigravityProxy.exe (one URL or port number)',
        $ProxyUrl.Trim()
    )
    Set-Content -LiteralPath $confPath -Value $lines -Encoding ASCII
    Write-Host ('Wrote proxy config: ' + $confPath + ' -> ' + $ProxyUrl.Trim()) -ForegroundColor Green
} elseif (-not (Test-Path -LiteralPath $confPath)) {
    # Smooth upgrade: migrate custom port from existing Antigravity-Proxy.cmd if present.
    $oldCmd = Join-Path $outDir 'Antigravity-Proxy.cmd'
    if (Test-Path -LiteralPath $oldCmd) {
        $match = Select-String -LiteralPath $oldCmd -Pattern 'ANTIGRAVITY_PROXY=([^\s"]+)' | Select-Object -First 1
        if ($match) {
            $migrated = $match.Matches[0].Groups[1].Value.Trim()
            if ($migrated) {
                $lines = @(
                    '# Migrated from Antigravity-Proxy.cmd',
                    $migrated
                )
                Set-Content -LiteralPath $confPath -Value $lines -Encoding ASCII
                Write-Host ('Migrated proxy config: ' + $confPath + ' -> ' + $migrated) -ForegroundColor Cyan
            }
        }
    }
}
