@echo off
title TPTS Core Dashboard Launcher

:: Force working directory to current folder
cd /d "%~dp0"

echo [1/3] Killing leftover processes...
taskkill /f /im tpts_backend.exe >nul 2>&1

echo [2/3] Launching Go server...
start /min "TPTS Core Engine" /d "%~dp0proxy" "%~dp0proxy\tpts_backend.exe"

echo [3/3] Waiting for dashboard...
set "BACKEND_READY="
for /l %%i in (1,1,15) do (
	curl.exe --silent --fail --max-time 1 http://127.0.0.1:8080/healthz >nul 2>&1 && set "BACKEND_READY=1"
	if defined BACKEND_READY goto backend_ready
	timeout /t 1 /nobreak >nul
)

echo [Error] Go server did not become ready at http://localhost:8080.
exit /b 1

:backend_ready
start /b "" "%~dp0proxy\adb.exe" start-server >nul 2>&1
start /b "" "%~dp0proxy\adb.exe" shell su 0 svc power stayon true >nul 2>&1

echo.
echo ===================================================
echo  🚀 TPTS Dashboard Started
echo  🌐 Dashboard Link: http://localhost:8080
echo  ℹ  Enter the device IP in the dashboard, then establish the ADB link.
echo ===================================================
echo.

start "" http://localhost:8080

exit