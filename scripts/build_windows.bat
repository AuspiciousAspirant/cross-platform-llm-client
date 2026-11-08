@echo off
setlocal
cd /d "%~dp0\.."

echo ====================================================
echo   PrivateLM: Native Windows .exe Build ^& Package
echo ====================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1" %*
if errorlevel 1 (
    echo.
    echo [ERROR] Build failed. Please check the messages above.
    pause
    exit /b %errorlevel%
)

echo.
echo Standalone executable is ready in dist\PrivateLM-Windows-x64\privatelm.exe
pause
