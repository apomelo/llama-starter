@echo off
setlocal
set "ROOT=%~dp0"
set "PROXY=%ROOT%agents\start-proxy.ps1"
set "PIDFILE=%TEMP%\fcm_schema_proxy.pid"
set "PROXYPID="

echo.
echo  Schema-proxy (Claude Code / Codex on :9998, forwards to llama-server :9999):
echo    [1] New window   (proxy runs in its own console)
echo    [2] Shared       (proxy runs in THIS console, output interleaved)
echo    [3] Skip         (llama-server only, no proxy)
echo.
set "MODE=3"
set /p "MODE=  Choose [1/2/3, default 3]: "

if "%MODE%"=="1" goto proxy_new
if "%MODE%"=="2" goto proxy_shared
goto run_llama

:proxy_new
if exist "%PIDFILE%" del "%PIDFILE%" >nul 2>&1
powershell -NoProfile -Command "(Start-Process powershell -ArgumentList '-ExecutionPolicy','Bypass','-NoExit','-File','%PROXY%' -PassThru).Id | Set-Content -Encoding Ascii '%PIDFILE%'"
if exist "%PIDFILE%" set /p PROXYPID=<"%PIDFILE%"
goto run_llama

:proxy_shared
if exist "%PIDFILE%" del "%PIDFILE%" >nul 2>&1
powershell -NoProfile -Command "(Start-Process powershell -ArgumentList '-ExecutionPolicy','Bypass','-File','%PROXY%' -PassThru -NoNewWindow).Id | Set-Content -Encoding Ascii '%PIDFILE%'"
if exist "%PIDFILE%" set /p PROXYPID=<"%PIDFILE%"
goto run_llama

:run_llama
powershell -ExecutionPolicy Bypass -File "%ROOT%start-llama.ps1"

rem start-llama.ps1 has exited -> stop the proxy (and its node child) if we started one.
if defined PROXYPID (
    taskkill /PID %PROXYPID% /T /F >nul 2>&1
    echo  Stopped schema-proxy (PID %PROXYPID%).
)
if exist "%PIDFILE%" del "%PIDFILE%" >nul 2>&1

endlocal
pause
