@echo off
setlocal

set "PROJECT_DIR=%~dp0"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" set "PS_EXE=powershell.exe"

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_DIR%scripts\uninstall.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo Uninstall did not complete. Exit code: %EXIT_CODE%
) else (
    echo Uninstall finished.
)
pause
exit /b %EXIT_CODE%
