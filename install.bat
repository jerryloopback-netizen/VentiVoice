@echo off
chcp 65001 >nul
setlocal

set "PROJECT_DIR=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_DIR%scripts\install.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo 安装未完成，错误码: %EXIT_CODE%
) else (
    echo 安装流程已结束。
)
pause
exit /b %EXIT_CODE%
