@echo off
chcp 65001 >nul
echo 正在创建 VentiVoice 快捷方式...

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "VENV_PYTHONW=%SCRIPT_DIR%\.venv\Scripts\pythonw.exe"

if exist "%VENV_PYTHONW%" (
  set "TARGET_PYTHONW=%VENV_PYTHONW%"
) else (
  set "TARGET_PYTHONW=pythonw.exe"
)

powershell -Command ^
  "$ws = New-Object -ComObject WScript.Shell; ^
   $s = $ws.CreateShortcut('%SCRIPT_DIR%\VentiVoice.lnk'); ^
   $s.TargetPath = '%TARGET_PYTHONW%'; ^
   $s.Arguments = 'src/main.py'; ^
   $s.WorkingDirectory = '%SCRIPT_DIR%'; ^
   $s.IconLocation = '%SCRIPT_DIR%\logo.ico,0'; ^
   $s.Description = 'VentiVoice - 语音转写桌面工具'; ^
   $s.Save()"

if exist "%SCRIPT_DIR%\VentiVoice.lnk" (
    echo 快捷方式已创建: %SCRIPT_DIR%\VentiVoice.lnk
) else (
    echo 创建失败，请先运行 install.bat 完成环境初始化
)
pause
