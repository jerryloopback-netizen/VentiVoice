@echo off
chcp 65001 >nul
echo 正在创建 VentiVoice 快捷方式...

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

powershell -Command ^
  "$ws = New-Object -ComObject WScript.Shell; ^
   $s = $ws.CreateShortcut('%SCRIPT_DIR%\VentiVoice.lnk'); ^
   $s.TargetPath = 'pythonw.exe'; ^
   $s.Arguments = 'src/main.py'; ^
   $s.WorkingDirectory = '%SCRIPT_DIR%'; ^
   $s.IconLocation = '%SCRIPT_DIR%\logo.ico,0'; ^
   $s.Description = 'VentiVoice - 语音转写桌面工具'; ^
   $s.Save()"

if exist "%SCRIPT_DIR%\VentiVoice.lnk" (
    echo 快捷方式已创建: %SCRIPT_DIR%\VentiVoice.lnk
) else (
    echo 创建失败，请确保已安装 Python 并加入 PATH
)
pause
