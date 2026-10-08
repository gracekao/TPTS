@echo off
setlocal
set "REPO=gracekao/TPTS_v1.0"
set "RELEASE_TAG=geekbench-7.0.0"
set "ASSET=Geekbench-7.0.0-Android-Corporate.zip"
set "PACKAGE_DIR=%~dp0stress_apk\Geekbench-7.0.0-Android-Corporate"
set "DOWNLOAD_DIR=%TEMP%\TPTS-Geekbench"
set "ARCHIVE=%DOWNLOAD_DIR%\%ASSET%"

if exist "%PACKAGE_DIR%\geekbench_avx2" if exist "%PACKAGE_DIR%\geekbench_aarch64" if exist "%PACKAGE_DIR%\geekbench.plxr" if exist "%PACKAGE_DIR%\geekbench-workload.plxr" exit /b 0

echo [Geekbench] Package missing. Downloading the GitHub Release asset...
where gh >nul 2>&1
if errorlevel 1 (
    echo [Geekbench] GitHub CLI is not installed. Install gh and run "gh auth login".
    exit /b 1
)

gh auth status >nul 2>&1
if errorlevel 1 (
    echo [Geekbench] GitHub CLI is not authenticated. Run "gh auth login" first.
    exit /b 1
)

if not exist "%DOWNLOAD_DIR%" mkdir "%DOWNLOAD_DIR%"
gh release download "%RELEASE_TAG%" --repo "%REPO%" --pattern "%ASSET%" --dir "%DOWNLOAD_DIR%" --clobber
if errorlevel 1 (
    echo [Geekbench] Download failed. Confirm release asset "%ASSET%" exists and your account can access it.
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%ARCHIVE%' -DestinationPath '%~dp0stress_apk' -Force"
if errorlevel 1 (
    echo [Geekbench] Could not extract the package archive.
    exit /b 1
)

if not exist "%PACKAGE_DIR%\geekbench_avx2" (
    echo [Geekbench] Archive layout is incorrect; expected the Geekbench folder under stress_apk.
    exit /b 1
)
if not exist "%PACKAGE_DIR%\geekbench_aarch64" exit /b 1
if not exist "%PACKAGE_DIR%\geekbench.plxr" exit /b 1
if not exist "%PACKAGE_DIR%\geekbench-workload.plxr" exit /b 1

echo [Geekbench] Package installed successfully.
exit /b 0
