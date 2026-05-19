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
$MinPython = [version]"3.11"
$MaxPython = [version]"3.14"

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

function Test-SupportedPythonVersion {
    param([string]$VersionText)
    try {
        $parts = $VersionText.Trim().Split(".")
        $version = [version]"$($parts[0]).$($parts[1])"
        return $version -ge $MinPython -and $version -le $MaxPython
    } catch {
        return $false
    }
}

function Get-PythonVersion {
    param(
        [string]$Exe,
        [string[]]$Args = @()
    )
    $version = & $Exe @Args -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return ($version | Select-Object -First 1).Trim()
}

function Get-PythonCommand {
    $candidates = @(
        @{ Exe = "py"; Args = @("-3.14") },
        @{ Exe = "py"; Args = @("-3.13") },
        @{ Exe = "py"; Args = @("-3.12") },
        @{ Exe = "py"; Args = @("-3.11") },
        @{ Exe = "python"; Args = @() }
    )

    foreach ($candidate in $candidates) {
        if (-not (Test-CommandExists $candidate.Exe)) {
            continue
        }

        $args = @($candidate.Args)
        $version = Get-PythonVersion -Exe $candidate.Exe -Args $args
        if ($version -and (Test-SupportedPythonVersion $version)) {
            return [pscustomobject]@{
                Exe = $candidate.Exe
                Args = $args
                Version = $version
            }
        }
    }

    throw "未找到受支持的 Python 版本。请安装 Python 3.14；安装器会在本机 Python 3.11-3.14 中选择最高可用版本。"
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

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "ventivoice-write-config-$PID.py"
    Write-Utf8NoBom -Path $tempScript -Content $code

    try {
        & $VenvPython $tempScript $ConfigPath
        if ($LASTEXITCODE -ne 0) {
            throw "写入 LLM 配置失败。"
        }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\VENTIVOICE_PROVIDER_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:\VENTIVOICE_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:\VENTIVOICE_API_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\VENTIVOICE_MODEL -ErrorAction SilentlyContinue
    }
}

function Get-ImportedUserDataSummary {
    $code = @'
import json
import sys
from pathlib import Path

import yaml

config_path = Path(sys.argv[1])
corpus_path = Path(sys.argv[2])
blacklist_path = Path(sys.argv[3])

providers = []
if config_path.exists():
    config = yaml.safe_load(config_path.read_text(encoding="utf-8-sig")) or {}
    providers = list(((config.get("llm") or {}).get("providers") or {}).keys())

correct_words = set()
if corpus_path.exists():
    corpus = json.loads(corpus_path.read_text(encoding="utf-8-sig"))
    for entry in corpus.get("corrections", []):
        correct = str(entry.get("correct", "")).strip()
        if correct:
            correct_words.add(correct)

blacklist_count = 0
if blacklist_path.exists():
    blacklist = json.loads(blacklist_path.read_text(encoding="utf-8-sig"))
    if isinstance(blacklist, list):
        blacklist_count = len([word for word in blacklist if str(word).strip()])

print("API Providers: " + (", ".join(providers) if providers else "(未找到)"))
print(f"词库正确词数: {len(correct_words)}")
print(f"黑名单词数: {blacklist_count}")
'@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "ventivoice-import-summary-$PID.py"
    Write-Utf8NoBom -Path $tempScript -Content $code

    try {
        & $VenvPython $tempScript $ConfigPath (Join-Path $ProjectRoot "corpus\corrections.json") (Join-Path $ProjectRoot "corpus\blacklist.json")
        if ($LASTEXITCODE -ne 0) {
            throw "读取导入配置失败。请确认 config.yaml、corpus\corrections.json、corpus\blacklist.json 格式正确。"
        }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Normalize-ImportedUserData {
    $code = @'
import json
import sys
from pathlib import Path

import yaml

config_path = Path(sys.argv[1])
corpus_path = Path(sys.argv[2])
blacklist_path = Path(sys.argv[3])

if config_path.exists():
    config = yaml.safe_load(config_path.read_text(encoding="utf-8-sig")) or {}
    config_path.write_text(
        yaml.dump(config, allow_unicode=True, default_flow_style=False, sort_keys=False),
        encoding="utf-8",
    )

if corpus_path.exists():
    corpus = json.loads(corpus_path.read_text(encoding="utf-8-sig"))
    corpus_path.write_text(json.dumps(corpus, ensure_ascii=False, indent=2), encoding="utf-8")

if blacklist_path.exists():
    blacklist = json.loads(blacklist_path.read_text(encoding="utf-8-sig"))
    blacklist_path.write_text(json.dumps(blacklist, ensure_ascii=False, indent=2), encoding="utf-8")
'@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "ventivoice-normalize-import-$PID.py"
    Write-Utf8NoBom -Path $tempScript -Content $code

    try {
        & $VenvPython $tempScript $ConfigPath (Join-Path $ProjectRoot "corpus\corrections.json") (Join-Path $ProjectRoot "corpus\blacklist.json")
        if ($LASTEXITCODE -ne 0) {
            throw "规范化导入配置失败。"
        }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Import-ExistingUserData {
    $configTarget = $ConfigPath
    $corpusTarget = Join-Path $ProjectRoot "corpus\corrections.json"
    $blacklistTarget = Join-Path $ProjectRoot "corpus\blacklist.json"

    while ($true) {
        Write-Host ""
        Write-Host "请现在手动替换旧配置文件到以下位置:"
        Write-Host "  API 配置: $configTarget"
        Write-Host "  词库文件: $corpusTarget"
        Write-Host "  黑名单:   $blacklistTarget"
        Write-Host "如果某个文件不存在，可以跳过该文件。"

        $done = Read-Host "替换完成后输入 y 继续"
        if ($done -notmatch "^(y|Y)$") {
            Write-Warn "等待你完成手动替换。"
            continue
        }

        Write-Step "读取导入结果"
        Get-ImportedUserDataSummary

        $confirm = Read-Host "以上导入结果是否正确? [y/N]"
        if ($confirm -match "^(y|Y)$") {
            Normalize-ImportedUserData
            return
        }

        Write-Warn "请重新手动替换需要导入的文件。"
    }
}

function Test-PathInsideProject {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return $fullPath.StartsWith($ProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Reset-VenvIfUnsupported {
    if (-not (Test-Path -LiteralPath $VenvPython)) {
        return
    }

    $version = Get-PythonVersion -Exe $VenvPython
    if ($version -and (Test-SupportedPythonVersion $version)) {
        Write-Ok ".venv 已存在，Python $version，复用当前环境"
        return
    }

    if (-not (Test-PathInsideProject $VenvDir)) {
        throw "拒绝删除项目目录外的虚拟环境: $VenvDir"
    }

    if (-not $version) {
        Write-Warn ".venv 已存在但无法读取 Python 版本，将重建。"
    } else {
        Write-Warn ".venv 使用 Python $version，不在支持范围 3.11-3.14，将重建。"
    }
    Remove-Item -LiteralPath $VenvDir -Recurse -Force
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
Reset-VenvIfUnsupported
if (-not (Test-Path -LiteralPath $VenvPython)) {
    & $Python.Exe @($Python.Args) -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) {
        throw "创建虚拟环境失败。"
    }
    Write-Ok "已创建 .venv"
}

Write-Step "安装 Python 依赖"
Invoke-VenvPython @("-m", "pip", "install", "-U", "pip")
Invoke-VenvPython @("-m", "pip", "install", "--only-binary=:all:", "-r", (Join-Path $ProjectRoot "requirements.txt"))

Write-Step "初始化配置文件"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Copy-Item -LiteralPath $ConfigExamplePath -Destination $ConfigPath
    Write-Ok "已从 config.yaml.example 创建 config.yaml"
} else {
    Write-Ok "config.yaml 已存在，未覆盖"
}
New-Item -ItemType Directory -Path (Join-Path $ProjectRoot "corpus") -Force | Out-Null

$importExisting = Read-Host "是否已有旧 API 配置文件或词库文件需要导入? [y/N]"
if ($importExisting -match "^(y|Y)") {
    Import-ExistingUserData
    Write-Ok "已确认导入旧配置和词库。"
} else {
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
}

if (-not $SkipModelDownload) {
    Write-Step "选择 ASR 模型"
    Write-Host "1. SenseVoice-Small（推荐，默认，只下载约 230MB）"
    Write-Host "2. Paraformer-Large（中文备用）"
    Write-Host "3. SenseVoice-2025 / sensevoice-large"
    Write-Host "4. 下载全部模型"
    Write-Host "5. 暂不下载"
    $choice = Read-Default "请选择" "1"

    if ($choice -eq "5") {
        Write-Warn "跳过模型下载。未下载模型时程序无法执行本地 ASR。"
    } else {
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
            default {
                Write-Warn "选择无效，按默认下载 SenseVoice-Small。"
                Invoke-VenvPython @((Join-Path $ProjectRoot "scripts\download_models.py"), "--model", "sensevoice-small", "--source", $source)
            }
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
