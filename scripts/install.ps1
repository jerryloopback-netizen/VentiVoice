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
$VcRedistX64Url = "https://aka.ms/vc14/vc_redist.x64.exe"

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

function Get-PythonInfo {
    param(
        [string]$Exe,
        [string[]]$Args = @()
    )
    $output = & $Exe @Args -c "import sys; print('.'.join(map(str, sys.version_info[:3]))); print('64' if sys.maxsize > 2**32 else '32'); print(sys.executable)" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return $null
    }
    $lines = @($output | ForEach-Object { [string]$_ })
    if ($lines.Count -lt 3) {
        return $null
    }
    return [pscustomobject]@{
        Version = $lines[0].Trim()
        Is64Bit = $lines[1].Trim() -eq "64"
        Path = $lines[2].Trim()
    }
}

function New-PythonCandidate {
    param(
        [string]$Exe,
        [string[]]$Args = @()
    )

    return [pscustomobject]@{
        Exe = $Exe
        Args = $Args
    }
}

function Get-PythonLauncherCandidates {
    if (-not (Test-CommandExists "py")) {
        return @()
    }

    $candidates = @()
    $launcherOutput = & py -0p 2>$null
    foreach ($line in @($launcherOutput)) {
        $text = [string]$line
        if ($text -match "-V:(3\.(11|12|13|14))\s+\*?\s*(.+python\.exe)\s*$") {
            $version = $matches[1]
            $path = $matches[3].Trim()
            if (Test-Path -LiteralPath $path) {
                $candidates += (New-PythonCandidate -Exe $path)
            }
            $candidates += (New-PythonCandidate -Exe "py" -Args @("-$version-64"))
            $candidates += (New-PythonCandidate -Exe "py" -Args @("-$version"))
        }
    }

    $candidates += (New-PythonCandidate -Exe "py" -Args @("-3.14-64"))
    $candidates += (New-PythonCandidate -Exe "py" -Args @("-3.14"))
    $candidates += (New-PythonCandidate -Exe "py" -Args @("-3.13-64"))
    $candidates += (New-PythonCandidate -Exe "py" -Args @("-3.13"))
    $candidates += (New-PythonCandidate -Exe "py" -Args @("-3.12-64"))
    $candidates += (New-PythonCandidate -Exe "py" -Args @("-3.12"))
    $candidates += (New-PythonCandidate -Exe "py" -Args @("-3.11-64"))
    $candidates += (New-PythonCandidate -Exe "py" -Args @("-3.11"))

    return $candidates
}

function Get-PythonCandidates {
    $candidates = @()
    $candidates += Get-PythonLauncherCandidates

    if (Test-CommandExists "python") {
        $candidates += (New-PythonCandidate -Exe "python")
    }

    $seen = @{}
    $result = @()
    foreach ($candidate in $candidates) {
        $key = "$($candidate.Exe)|$($candidate.Args -join ' ')"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $candidate
        }
    }

    return $result
}

function Get-PythonCommand {
    $valid = @()
    foreach ($candidate in (Get-PythonCandidates)) {
        if (($candidate.Exe -notmatch "^[A-Za-z]:\\") -and (-not (Test-CommandExists $candidate.Exe))) {
            continue
        }

        $args = @($candidate.Args)
        $info = Get-PythonInfo -Exe $candidate.Exe -Args $args
        if ($info -and $info.Is64Bit -and (Test-SupportedPythonVersion $info.Version)) {
            $valid += [pscustomobject]@{
                Exe = $candidate.Exe
                Args = $args
                Version = $info.Version
                VersionKey = [version]$info.Version
                Path = $info.Path
            }
        }
    }

    if ($valid.Count -gt 0) {
        return ($valid | Sort-Object VersionKey -Descending | Select-Object -First 1)
    }

    throw "未找到受支持的 64 位 Python 版本。请安装 64 位 Python 3.11-3.14；安装器会在本机 Python 3.11-3.14 中选择最高可用版本。"
}

function Test-VenvPipAvailable {
    if (-not (Test-Path -LiteralPath $VenvPython)) {
        return $false
    }

    & $VenvPython -m pip --version 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Repair-VenvPip {
    if (Test-VenvPipAvailable) {
        return $true
    }

    Write-Warn ".venv 中未检测到 pip，尝试用 ensurepip 修复。"
    & $VenvPython -m ensurepip --upgrade
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    & $VenvPython -m pip install -U pip
    return $LASTEXITCODE -eq 0
}

function Invoke-VenvPython {
    param([string[]]$Arguments)
    & $VenvPython @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python 命令执行失败: $VenvPython $($Arguments -join ' ')"
    }
}

function Get-VcRedistX64Info {
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
    )

    foreach ($path in $registryPaths) {
        try {
            $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            if ($item.Installed -eq 1) {
                return [pscustomobject]@{
                    Installed = $true
                    Version = [string]$item.Version
                    Path = $path
                }
            }
        } catch {
        }
    }

    return [pscustomobject]@{
        Installed = $false
        Version = ""
        Path = ""
    }
}

function Test-VcRuntimeDllsPresent {
    $system32 = Join-Path $env:WINDIR "System32"
    $dlls = @("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll")
    foreach ($dll in $dlls) {
        if (-not (Test-Path -LiteralPath (Join-Path $system32 $dll))) {
            return $false
        }
    }
    return $true
}

function Test-VcRedistX64Installed {
    $info = Get-VcRedistX64Info
    return $info.Installed -and (Test-VcRuntimeDllsPresent)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-VcRedistX64 {
    Write-Warn "未检测到完整的 Microsoft Visual C++ 2015-2022 Redistributable (x64)。"
    Write-Host "下载地址: $VcRedistX64Url"

    $choice = Read-Host "是否现在自动下载安装 VC++ x64 运行库? [Y/n]"
    if ($choice -match "^(n|N)$") {
        Write-Warn "已跳过 VC++ 运行库安装。若后续出现 DLL load failed，请手动安装上面的官方链接。"
        return $false
    }

    $installer = Join-Path ([System.IO.Path]::GetTempPath()) "vc_redist.x64.exe"
    try {
        Write-Host "正在下载 VC++ x64 运行库..."
        Invoke-WebRequest -Uri $VcRedistX64Url -OutFile $installer -UseBasicParsing

        Write-Host "正在安装 VC++ x64 运行库，可能会弹出 Windows 权限确认窗口..."
        if (Test-IsAdministrator) {
            $process = Start-Process -FilePath $installer -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
        } else {
            $process = Start-Process -FilePath $installer -ArgumentList "/install", "/quiet", "/norestart" -Verb RunAs -Wait -PassThru
        }

        if (($process.ExitCode -notin @(0, 3010)) -and (-not (Test-VcRedistX64Installed))) {
            Write-Warn "VC++ 运行库安装程序退出码: $($process.ExitCode)"
            Write-Warn "请手动下载安装: $VcRedistX64Url"
            return $false
        }

        if ($process.ExitCode -eq 3010) {
            Write-Warn "VC++ 运行库安装完成，但 Windows 提示需要重启。建议重启后再次运行 install.bat。"
        } else {
            Write-Ok "VC++ x64 运行库安装完成"
        }
        return $true
    } catch {
        Write-Warn "自动安装 VC++ 运行库失败: $($_.Exception.Message)"
        Write-Warn "请手动下载安装: $VcRedistX64Url"
        return $false
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-VcRedistX64 {
    if (Test-VcRedistX64Installed) {
        $info = Get-VcRedistX64Info
        Write-Ok "已检测到 VC++ x64 运行库 $($info.Version)"
        return
    }

    [void](Install-VcRedistX64)
}

function Test-PythonModuleImport {
    param([string]$Module)

    $code = @'
import importlib
import sys
import traceback

module = sys.argv[1]
try:
    importlib.import_module(module)
except Exception:
    traceback.print_exc()
    sys.exit(1)
'@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "ventivoice-test-import-$PID.py"
    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) "ventivoice-test-import-$PID.out.txt"
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "ventivoice-test-import-$PID.err.txt"
    Write-Utf8NoBom -Path $tempScript -Content $code

    try {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        $process = Start-Process -FilePath $VenvPython -ArgumentList @("-X", "faulthandler", $tempScript, $Module) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue } else { "" }
        $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue } else { "" }
        return [pscustomobject]@{
            Success = ($process.ExitCode -eq 0)
            ExitCode = $process.ExitCode
            Output = (@($stdout, $stderr) -join [Environment]::NewLine).Trim()
        }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-CommonOnnxRuntimeDllLocations {
    $candidates = @()
    $candidates += @(
        (Join-Path $env:SystemDrive "onnxruntime.dll"),
        (Join-Path $env:SystemDrive "Windows\System32\onnxruntime.dll"),
        (Join-Path $ProjectRoot "onnxruntime.dll")
    )
    if (${env:ProgramFiles}) {
        $candidates += (Join-Path ${env:ProgramFiles} "onnxruntime.dll")
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "onnxruntime.dll")
    }

    $found = @()
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $found += (Get-Item -LiteralPath $candidate).FullName
        }
    }

    return $found
}

function Show-SherpaOnnxHints {
    $matches = Get-CommonOnnxRuntimeDllLocations
    if ($matches.Count -gt 0) {
        Write-Warn "检测到可能冲突的 onnxruntime.dll："
        foreach ($path in $matches) {
            Write-Host "  $path"
        }
        Write-Warn "sherpa-onnx 官方 FAQ 提到，C 盘上的旧版 onnxruntime.dll 可能会导致导入异常。"
        Write-Warn "如果你确认这些 DLL 不是别的程序必需的，请先移走或重命名这些旧文件，再重新运行 install.bat。"
    } else {
        Write-Warn "未在常见位置找到明显的 onnxruntime.dll 冲突文件。"
        Write-Warn "如果 sherpa_onnx 仍然失败，请检查是否有其他程序把旧版 onnxruntime.dll 放进了 PATH 或 C 盘根目录。"
    }
}

function Test-IsMissingPythonPackageError {
    param([string]$Output)
    return $Output -match "ModuleNotFoundError|No module named"
}

function Test-IsBinaryRuntimeError {
    param([string]$Output)
    return $Output -match "DLL load failed|LoadLibrary|cannot load library|specified module could not be found|找不到指定的模块|动态链接库|VCRUNTIME|MSVCP|vcruntime|msvcp|WinError 126|WinError 127|WinError 193"
}

function Test-CriticalDependencies {
    $dependencies = @(
        @{ Module = "sherpa_onnx"; Package = "sherpa-onnx"; Binary = $true; Hint = "ASR 推理运行时" },
        @{ Module = "sounddevice"; Package = "sounddevice"; Binary = $true; Hint = "录音与 PortAudio" },
        @{ Module = "numpy"; Package = "numpy"; Binary = $true; Hint = "音频数组处理" },
        @{ Module = "PIL"; Package = "Pillow"; Binary = $true; Hint = "托盘图标处理" },
        @{ Module = "yaml"; Package = "pyyaml"; Binary = $false; Hint = "配置文件读取" },
        @{ Module = "httpx"; Package = "httpx"; Binary = $false; Hint = "LLM API 请求" },
        @{ Module = "pynput"; Package = "pynput"; Binary = $false; Hint = "全局热键" },
        @{ Module = "pyperclip"; Package = "pyperclip"; Binary = $false; Hint = "剪贴板" },
        @{ Module = "pystray"; Package = "pystray"; Binary = $false; Hint = "系统托盘" },
        @{ Module = "tkinter"; Package = ""; Binary = $false; Hint = "桌面界面，通常随官方 Python 安装" }
    )

    foreach ($dep in $dependencies) {
        $result = Test-PythonModuleImport -Module $dep.Module
        if ($result.Success) {
            Write-Ok "$($dep.Module) ($($dep.Hint))"
            continue
        }

        Write-Warn "$($dep.Module) 导入失败。"

        if ((Test-IsMissingPythonPackageError $result.Output) -and $dep.Package) {
            Write-Warn "检测到缺少 Python 包，正在自动补装: $($dep.Package)"
            Invoke-VenvPython @("-m", "pip", "install", "--only-binary=:all:", $dep.Package)
            $retry = Test-PythonModuleImport -Module $dep.Module
            if ($retry.Success) {
                Write-Ok "$($dep.Module) 已修复"
                continue
            }
            $result = $retry
        }

        if ((Test-IsBinaryRuntimeError $result.Output) -or $dep.Binary) {
            Write-Warn "这类错误通常与 Windows 二进制运行库或 DLL 加载有关。"
            if (-not (Test-VcRedistX64Installed)) {
                [void](Install-VcRedistX64)
                $retryAfterVc = Test-PythonModuleImport -Module $dep.Module
                if ($retryAfterVc.Success) {
                    Write-Ok "$($dep.Module) 已在安装 VC++ 运行库后修复"
                    continue
                }
                $result = $retryAfterVc
            }
        }

        if ($dep.Module -eq "sherpa_onnx") {
            Show-SherpaOnnxHints
        }

        Write-Host ""
        Write-Host "依赖导入失败: $($dep.Module)" -ForegroundColor Red
        Write-Host "用途: $($dep.Hint)"
        if ($dep.Package) {
            Write-Host "Python 包: $($dep.Package)"
        }
        Write-Host "退出码: $($result.ExitCode)"
        Write-Host "VC++ x64 运行库官方下载: $VcRedistX64Url"
        Write-Host "原始错误:"
        if ($result.Output) {
            Write-Host $result.Output
        } else {
            Write-Host "(无额外输出)"
        }
        throw "关键依赖验证失败: $($dep.Module)"
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
    param([string]$ExpectedVersion)

    if (-not (Test-Path -LiteralPath $VenvPython)) {
        return
    }

    $info = Get-PythonInfo -Exe $VenvPython
    if ($info -and $info.Is64Bit -and (Test-SupportedPythonVersion $info.Version) -and ($info.Version -eq $ExpectedVersion)) {
        Write-Ok ".venv 已存在，Python $($info.Version)，复用当前环境"
        return
    }

    if (-not (Test-PathInsideProject $VenvDir)) {
        throw "拒绝删除项目目录外的虚拟环境: $VenvDir"
    }

    if (-not $info) {
        Write-Warn ".venv 已存在但无法读取 Python 版本，将重建。"
    } elseif (-not $info.Is64Bit) {
        Write-Warn ".venv 使用 32 位 Python $($info.Version)，不支持当前二进制依赖，将重建。"
    } elseif ($info.Version -ne $ExpectedVersion) {
        Write-Warn ".venv 使用 Python $($info.Version)，与本次选择的 Python $ExpectedVersion 不一致，将重建。"
    } else {
        Write-Warn ".venv 使用 Python $($info.Version)，不在支持范围 3.11-3.14，将重建。"
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
Write-Ok "找到 Python $($Python.Version): $($Python.Path)"

Write-Step "创建虚拟环境"
Reset-VenvIfUnsupported -ExpectedVersion $Python.Version
if (-not (Test-Path -LiteralPath $VenvPython)) {
    & $Python.Exe @($Python.Args) -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) {
        throw "创建虚拟环境失败。"
    }
    Write-Ok "已创建 .venv"
}

if (-not (Repair-VenvPip)) {
    Write-Warn ".venv 的 pip 修复失败，将重建虚拟环境。"
    if (-not (Test-PathInsideProject $VenvDir)) {
        throw "拒绝删除项目目录外的虚拟环境: $VenvDir"
    }
    Remove-Item -LiteralPath $VenvDir -Recurse -Force
    & $Python.Exe @($Python.Args) -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) {
        throw "重建虚拟环境失败。"
    }
    if (-not (Repair-VenvPip)) {
        throw "虚拟环境 pip 不可用。请确认所选 Python 安装包含 ensurepip/pip。"
    }
    Write-Ok "已重建 .venv 并修复 pip"
}

Write-Step "检查 Windows 二进制运行库"
Ensure-VcRedistX64

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
Test-CriticalDependencies

Write-Host ""
Write-Ok "安装完成。"
Write-Host "启动方式:"
Write-Host "  双击 run.bat"
Write-Host "  或双击桌面 VentiVoice 快捷方式"
Write-Host "排错方式:"
Write-Host "  双击 run_debug.bat 查看控制台错误"
