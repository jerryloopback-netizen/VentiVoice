param(
    [switch]$SkipModelDownload,
    [switch]$SkipShortcut
)

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch {
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir ".."))
$VenvDir = Join-Path $ProjectRoot ".venv"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$VenvPythonw = Join-Path $VenvDir "Scripts\pythonw.exe"
$ConfigPath = Join-Path $ProjectRoot "config.yaml"
$ConfigExamplePath = Join-Path $ProjectRoot "config.yaml.example"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[提示] $Message" -ForegroundColor Yellow
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Test-CommandExists {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-PythonCommand {
    $candidates = @(
        @{ Exe = "py"; Args = @("-3") },
        @{ Exe = "python"; Args = @() }
    )

    foreach ($candidate in $candidates) {
        if (-not (Test-CommandExists $candidate.Exe)) {
            continue
        }

        $args = @($candidate.Args)
        $version = & $candidate.Exe @args -c "import sys; print('.'.join(map(str, sys.version_info[:3]))); raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{
                Exe = $candidate.Exe
                Args = $args
                Version = $version
            }
        }
    }

    throw "未找到 Python 3.10+。请先安装 Python 3.10 或更新版本，并勾选 py launcher 或加入 PATH。"
}

function Invoke-VenvPython {
    param([string[]]$Arguments)
    & $VenvPython @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python 命令执行失败: $VenvPython $($Arguments -join ' ')"
    }
}

function Read-Default {
    param(
        [string]$Prompt,
        [string]$Default
    )
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function Read-SecretText {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    if ($secure.Length -eq 0) {
        return ""
    }

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Update-LlmConfig {
    param(
        [string]$ProviderName,
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Model
    )

    $env:VENTIVOICE_PROVIDER_NAME = $ProviderName
    $env:VENTIVOICE_BASE_URL = $BaseUrl
    $env:VENTIVOICE_API_KEY = $ApiKey
    $env:VENTIVOICE_MODEL = $Model

    $code = @'
import os
import sys
from pathlib import Path

import yaml

path = Path(sys.argv[1])
config = yaml.safe_load(path.read_text(encoding="utf-8"))

provider = os.environ["VENTIVOICE_PROVIDER_NAME"].strip()
base_url = os.environ["VENTIVOICE_BASE_URL"].strip()
api_key = os.environ["VENTIVOICE_API_KEY"]
model = os.environ["VENTIVOICE_MODEL"].strip()

llm = config.setdefault("llm", {})
providers = llm.setdefault("providers", {})
providers[provider] = {
    "base_url": base_url,
    "api_key": api_key,
    "model": model,
    "max_tokens": 2048,
    "temperature": 0.3,
}
llm["default_provider"] = provider

ui = config.setdefault("ui", {})
ui["last_llm_provider"] = provider

path.write_text(
    yaml.dump(config, allow_unicode=True, default_flow_style=False, sort_keys=False),
    encoding="utf-8",
)
'@

    try {
        & $VenvPython -c $code $ConfigPath
        if ($LASTEXITCODE -ne 0) {
            throw "写入 LLM 配置失败。"
        }
    } finally {
        Remove-Item Env:\VENTIVOICE_PROVIDER_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:\VENTIVOICE_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:\VENTIVOICE_API_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\VENTIVOICE_MODEL -ErrorAction SilentlyContinue
    }
}

function Write-RunScripts {
    $runBat = @'
@echo off
chcp 65001 >nul
cd /d "%~dp0"
start "" "%~dp0.venv\Scripts\pythonw.exe" "%~dp0src\main.py"
'@

    $debugBat = @'
@echo off
chcp 65001 >nul
cd /d "%~dp0"
"%~dp0.venv\Scripts\python.exe" "%~dp0src\main.py"
pause
'@

    Write-Utf8NoBom (Join-Path $ProjectRoot "run.bat") ($runBat.TrimStart())
    Write-Utf8NoBom (Join-Path $ProjectRoot "run_debug.bat") ($debugBat.TrimStart())
}

function New-VentiVoiceShortcut {
    param([string]$ShortcutPath)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $VenvPythonw
    $shortcut.Arguments = "`"$ProjectRoot\src\main.py`""
    $shortcut.WorkingDirectory = $ProjectRoot
    $shortcut.IconLocation = "$ProjectRoot\logo.ico,0"
    $shortcut.Description = "VentiVoice - 语音转写桌面工具"
    $shortcut.Save()
}

Write-Host "VentiVoice Windows 安装器"
Write-Host "项目目录: $ProjectRoot"

Write-Step "检查 Python"
$Python = Get-PythonCommand
Write-Ok "找到 Python $($Python.Version): $($Python.Exe) $($Python.Args -join ' ')"

Write-Step "创建虚拟环境"
if (-not (Test-Path -LiteralPath $VenvPython)) {
    & $Python.Exe @($Python.Args) -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) {
        throw "创建虚拟环境失败。"
    }
    Write-Ok "已创建 .venv"
} else {
    Write-Ok ".venv 已存在，复用当前环境"
}

Write-Step "安装 Python 依赖"
Invoke-VenvPython @("-m", "pip", "install", "-U", "pip")
Invoke-VenvPython @("-m", "pip", "install", "-r", (Join-Path $ProjectRoot "requirements.txt"))

Write-Step "初始化配置文件"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Copy-Item -LiteralPath $ConfigExamplePath -Destination $ConfigPath
    Write-Ok "已从 config.yaml.example 创建 config.yaml"
} else {
    Write-Ok "config.yaml 已存在，未覆盖"
}

$configure = Read-Host "是否现在写入初始 LLM API 配置? [y/N]"
if ($configure -match "^(y|Y)") {
    $providerName = Read-Default "配置名称" "my-provider"
    $baseUrl = Read-Default "Base URL" "https://api.openai.com/v1"
    $apiKey = Read-SecretText "API Key（输入不会显示，回车可留空）"
    $model = Read-Default "LLM 模型名" "gpt-4o-mini"
    Update-LlmConfig -ProviderName $providerName -BaseUrl $baseUrl -ApiKey $apiKey -Model $model
    Write-Ok "已写入 LLM 配置: $providerName"
} else {
    Write-Warn "跳过 API 写入。你仍可启动程序后在界面中配置 LLM。"
}

if (-not $SkipModelDownload) {
    Write-Step "选择 ASR 模型"
    Write-Host "1. SenseVoice-Small（推荐，默认，只下载约 230MB）"
    Write-Host "2. Paraformer-Large（中文备用）"
    Write-Host "3. SenseVoice-2025 / sensevoice-large"
    Write-Host "4. 下载全部模型"
    Write-Host "5. 暂不下载"
    $choice = Read-Default "请选择" "1"

    $source = Read-Default "下载源 auto / official / hf-mirror" "auto"
    if ($source -notin @("auto", "official", "hf-mirror")) {
        Write-Warn "下载源无效，改用 auto。"
        $source = "auto"
    }

    switch ($choice) {
        "1" { Invoke-VenvPython @((Join-Path $ProjectRoot "scripts\download_models.py"), "--model", "sensevoice-small", "--source", $source) }
        "2" { Invoke-VenvPython @((Join-Path $ProjectRoot "scripts\download_models.py"), "--model", "paraformer-large", "--source", $source) }
        "3" { Invoke-VenvPython @((Join-Path $ProjectRoot "scripts\download_models.py"), "--model", "sensevoice-large", "--source", $source) }
        "4" { Invoke-VenvPython @((Join-Path $ProjectRoot "scripts\download_models.py"), "--all", "--source", $source) }
        "5" { Write-Warn "跳过模型下载。未下载模型时程序无法执行本地 ASR。" }
        default {
            Write-Warn "选择无效，按默认下载 SenseVoice-Small。"
            Invoke-VenvPython @((Join-Path $ProjectRoot "scripts\download_models.py"), "--model", "sensevoice-small", "--source", $source)
        }
    }
}

Write-Step "生成启动脚本"
Write-RunScripts
Write-Ok "已生成 run.bat 和 run_debug.bat"

if (-not $SkipShortcut) {
    $shortcutChoice = Read-Host "是否创建桌面快捷方式? [Y/n]"
    if ($shortcutChoice -notmatch "^(n|N)") {
        $desktop = [Environment]::GetFolderPath("Desktop")
        New-VentiVoiceShortcut -ShortcutPath (Join-Path $desktop "VentiVoice.lnk")
        New-VentiVoiceShortcut -ShortcutPath (Join-Path $ProjectRoot "VentiVoice.lnk")
        Write-Ok "已创建快捷方式"
    }
}

Write-Step "验证关键依赖"
Invoke-VenvPython @("-c", "import sherpa_onnx, sounddevice, pynput, pyperclip, yaml, httpx; print('依赖导入成功')")

Write-Host ""
Write-Ok "安装完成。"
Write-Host "启动方式:"
Write-Host "  双击 run.bat"
Write-Host "  或双击桌面 VentiVoice 快捷方式"
Write-Host "排错方式:"
Write-Host "  双击 run_debug.bat 查看控制台错误"
