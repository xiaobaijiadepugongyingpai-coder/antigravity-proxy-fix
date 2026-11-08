@echo off
REM ============================================================
REM  Antigravity launcher WITH proxy (for this app only)
REM
REM  Why this is needed:
REM  Antigravity has two parts:
REM    1) Electron shell (Antigravity.exe)      - respects Windows system proxy
REM    2) Go language server (language_server.exe) - ONLY reads HTTP_PROXY /
REM       HTTPS_PROXY env vars. It ignores the Windows system proxy entirely.
REM  So with only the system proxy on, the shell works but the Go core
REM  cannot reach Google, and the window stays stuck loading
REM  (ERR_TIMED_OUT on https://127.0.0.1:PORT/).
REM
REM  This script changes nothing globally. It only sets env vars for the
REM  Antigravity process it starts.
REM ============================================================

setlocal

REM ---- configurable: proxy address ----
if not defined ANTIGRAVITY_PROXY set "ANTIGRAVITY_PROXY=http://127.0.0.1:7897"

REM loopback must NEVER go through the proxy
set "NO_PROXY=localhost,127.0.0.1,::1"
set "no_proxy=localhost,127.0.0.1,::1"

set "HTTPS_PROXY=%ANTIGRAVITY_PROXY%"
set "HTTP_PROXY=%ANTIGRAVITY_PROXY%"
set "https_proxy=%ANTIGRAVITY_PROXY%"
set "http_proxy=%ANTIGRAVITY_PROXY%"

set "APP=%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe"

if not exist "%APP%" (
    echo [ERROR] Antigravity.exe not found
    echo   expected: %APP%
    echo.
    pause
    exit /b 1
)

REM probe the proxy port; warn only, never block startup
powershell -NoProfile -Command "$h=$env:HTTPS_PROXY -replace '^https?://',''; $p=[int]($h -split ':')[-1]; $ok=$false; try{ $c=New-Object Net.Sockets.TcpClient; $r=$c.BeginConnect('127.0.0.1',$p,$null,$null); $ok=$r.AsyncWaitHandle.WaitOne(800); if($ok){$c.EndConnect($r)}; $c.Close() }catch{}; if(-not $ok){ Write-Host ('[WARN] proxy port ' + $p + ' not responding; Clash may be off.') -ForegroundColor Yellow; Start-Sleep -Seconds 2 }"

start "" "%APP%"

endlocal
