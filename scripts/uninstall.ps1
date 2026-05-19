param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch {
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir ".."))

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-PathInsideProject {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return $fullPath.StartsWith($ProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-ProjectItem {
    param(
        [string]$RelativePath,
        [switch]$Recurse
    )

    $target = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $RelativePath))
    if (-not (Test-PathInsideProject $target)) {
        throw "拒绝删除项目目录外路径: $target"
    }

    if (Test-Path -LiteralPath $target) {
        Write-Host "删除: $target"
        if ($Recurse) {
            Remove-Item -LiteralPath $target -Recurse -Force
        } else {
            Remove-Item -LiteralPath $target -Force
        }
    }
}

function Remove-Shortcut {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Write-Host "删除: $Path"
        Remove-Item -LiteralPath $Path -Force
    }
}

Write-Host "VentiVoice Windows 卸载器"
Write-Host "项目目录: $ProjectRoot"
Write-Host ""
Write-Host "将删除以下安装/运行生成内容:"
Write-Host "  .venv/"
Write-Host "  models/"
Write-Host "  config.yaml"
Write-Host "  corpus/corrections.json, corpus/blacklist.json, corpus/last_result.txt"
Write-Host "  test_output/"
Write-Host "  run.bat, run_debug.bat, VentiVoice.lnk"
Write-Host "  桌面 VentiVoice.lnk"
Write-Host ""
Write-Host "不会删除源码、README、prompts、config.yaml.example 或 corpus/corrections.json.example。"

if (-not $Force) {
    $confirm = Read-Host "确认卸载并删除以上内容? 输入 y 继续"
    if ($confirm -notmatch "^(y|Y)$") {
        Write-Host "已取消。"
        exit 0
    }
}

Write-Step "删除项目内生成内容"
Remove-ProjectItem ".venv" -Recurse
Remove-ProjectItem "models" -Recurse
Remove-ProjectItem "test_output" -Recurse
Remove-ProjectItem "config.yaml"
Remove-ProjectItem "run.bat"
Remove-ProjectItem "run_debug.bat"
Remove-ProjectItem "VentiVoice.lnk"
Remove-ProjectItem "corpus\corrections.json"
Remove-ProjectItem "corpus\blacklist.json"
Remove-ProjectItem "corpus\last_result.txt"

Write-Step "删除桌面快捷方式"
$desktop = [Environment]::GetFolderPath("Desktop")
Remove-Shortcut (Join-Path $desktop "VentiVoice.lnk")

Write-Host ""
Write-Host "[OK] 卸载完成。"
