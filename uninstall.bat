@echo off
chcp 65001 >nul
setlocal

set "PROJECT_DIR=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_DIR%scripts\uninstall.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo 卸载未完成，错误码: %EXIT_CODE%
) else (
    echo 卸载流程已结束。
)
pause
exit /b %EXIT_CODE%
