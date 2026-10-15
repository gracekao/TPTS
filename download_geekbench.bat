@echo off
setlocal
set "ASSET=Geekbench-7.0.0-Android-Corporate.zip"
set "ASSET_URL=https://github.com/gracekao/TPTS/releases/download/geekbench-7.0.0/%ASSET%"
set "PACKAGE_DIR=%~dp0stress_apk\Geekbench-7.0.0-Android-Corporate"
set "DOWNLOAD_DIR=%TEMP%\TPTS-Geekbench"
set "ARCHIVE=%DOWNLOAD_DIR%\%ASSET%"

if exist "%PACKAGE_DIR%\geekbench_avx2" if exist "%PACKAGE_DIR%\geekbench_aarch64" if exist "%PACKAGE_DIR%\geekbench.plxr" if exist "%PACKAGE_DIR%\geekbench-workload.plxr" exit /b 0

echo [Geekbench] Package missing. Downloading %ASSET_URL%
where curl.exe >nul 2>&1
if errorlevel 1 (
    echo [Geekbench] curl.exe was not found. Download the file above and extract it under stress_apk\.
    exit /b 1
)

if not exist "%DOWNLOAD_DIR%" mkdir "%DOWNLOAD_DIR%"
curl.exe --fail --location --silent --show-error --retry 3 --retry-delay 5 --connect-timeout 30 -o "%ARCHIVE%" "%ASSET_URL%"
if errorlevel 1 (
    echo [Geekbench] Download failed. Check the network or proxy, or download the file above and extract it under stress_apk\.
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%ARCHIVE%' -DestinationPath '%~dp0stress_apk' -Force"
if errorlevel 1 (
    echo [Geekbench] Could not extract the package archive.
    exit /b 1
)
del /q "%ARCHIVE%" >nul 2>&1

for %%F in (geekbench_avx2 geekbench_aarch64 geekbench.plxr geekbench-workload.plxr) do (
    if not exist "%PACKAGE_DIR%\%%F" (
        echo [Geekbench] Archive layout is incorrect; missing %%F under stress_apk\Geekbench-7.0.0-Android-Corporate.
        exit /b 1
    )
)

echo [Geekbench] Package installed successfully.
exit /b 0