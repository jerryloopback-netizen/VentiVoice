@echo off
echo Creating VentiVoice shortcut...

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "VENV_PYTHONW=%SCRIPT_DIR%\.venv\Scripts\pythonw.exe"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" set "PS_EXE=powershell.exe"

if exist "%VENV_PYTHONW%" (
  set "TARGET_PYTHONW=%VENV_PYTHONW%"
) else (
  set "TARGET_PYTHONW=pythonw.exe"
)

"%PS_EXE%" -NoProfile -Command ^
  "$ws = New-Object -ComObject WScript.Shell; ^
   $s = $ws.CreateShortcut('%SCRIPT_DIR%\VentiVoice.lnk'); ^
   $s.TargetPath = '%TARGET_PYTHONW%'; ^
   $s.Arguments = 'src/main.py'; ^
   $s.WorkingDirectory = '%SCRIPT_DIR%'; ^
   $s.IconLocation = '%SCRIPT_DIR%\logo.ico,0'; ^
   $s.Description = 'VentiVoice'; ^
   $s.Save()"

if exist "%SCRIPT_DIR%\VentiVoice.lnk" (
    echo Shortcut created: %SCRIPT_DIR%\VentiVoice.lnk
) else (
    echo Failed. Please run install.bat first.
)
pause
