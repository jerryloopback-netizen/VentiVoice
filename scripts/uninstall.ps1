param(
    [switch]$Force,
    [switch]$KeepUserData,
    [string]$ProjectRoot
)

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch {
}

$ScriptPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$ScriptDir = Split-Path -Parent $ScriptPath
$TempRoot = [System.IO.Path]::GetTempPath()

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $detectedProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir ".."))
    $tempScript = Join-Path $TempRoot ("ventivoice-uninstall-" + [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetRandomFileName()) + ".ps1")
    Copy-Item -LiteralPath $ScriptPath -Destination $tempScript -Force

    $relayArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $tempScript,
        "-ProjectRoot",
        $detectedProjectRoot
    )
    if ($Force) {
        $relayArgs += "-Force"
    }
    if ($KeepUserData) {
        $relayArgs += "-KeepUserData"
    }

    try {
        & powershell.exe @relayArgs
        exit $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$ProjectRootPrefix = $ProjectRoot.TrimEnd('\') + '\'

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

function Test-PathInsideProject {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return $fullPath.Equals($ProjectRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($ProjectRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativeProjectPath {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-PathInsideProject $fullPath)) {
        throw "拒绝处理项目目录外路径: $fullPath"
    }
    return $fullPath.Substring($ProjectRoot.Length).TrimStart('\')
}

function Stop-VentiVoiceProcesses {
    $candidates = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @("python.exe", "pythonw.exe") -and
        $_.CommandLine -and
        $_.CommandLine.IndexOf($ProjectRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }

    foreach ($proc in $candidates) {
        Write-Host "结束进程: $($proc.Name) (PID $($proc.ProcessId))"
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
        } catch {
            Write-Warn "无法结束进程 PID $($proc.ProcessId): $($_.Exception.Message)"
        }
    }
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
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        } else {
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
        }
    }
}

function Remove-WithRetry {
    param(
        [string]$RelativePath,
        [switch]$Recurse,
        [int]$RetryCount = 4
    )

    $target = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $RelativePath))
    if (-not (Test-Path -LiteralPath $target)) {
        return
    }

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Remove-ProjectItem -RelativePath $RelativePath -Recurse:$Recurse
            return
        } catch {
            if ($attempt -eq $RetryCount) {
                throw
            }
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
}

function Remove-Shortcut {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Write-Host "删除: $Path"
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Start-DelayedCleanup {
    param([string[]]$Paths)

    $existingPaths = @($Paths | Where-Object { Test-Path -LiteralPath $_ })
    if ($existingPaths.Count -eq 0) {
        return
    }

    $cleanupScript = Join-Path $TempRoot ("ventivoice-delayed-cleanup-" + [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetRandomFileName()) + ".ps1")
    $quotedPaths = $existingPaths | ForEach-Object {
        "'" + $_.Replace("'", "''") + "'"
    }
    $pathLiteral = "@(" + ($quotedPaths -join ", ") + ")"
    $content = @"
Start-Sleep -Seconds 2
`$paths = $pathLiteral
for (`$attempt = 0; `$attempt -lt 30; `$attempt++) {
    `$remaining = @()
    foreach (`$path in `$paths) {
        if (-not (Test-Path -LiteralPath `$path)) {
            continue
        }
        try {
            Remove-Item -LiteralPath `$path -Recurse -Force -ErrorAction Stop
        } catch {
            `$remaining += `$path
        }
    }
    if (`$remaining.Count -eq 0) {
        break
    }
    `$paths = `$remaining
    Start-Sleep -Seconds 1
}
Remove-Item -LiteralPath `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
"@
    [System.IO.File]::WriteAllText($cleanupScript, $content, [System.Text.UTF8Encoding]::new($true))
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $cleanupScript) -WindowStyle Hidden
}

function Get-BackupMap {
    $items = @(
        "config.yaml",
        "corpus\corrections.json",
        "corpus\blacklist.json"
    )

    $map = @{}
    foreach ($item in $items) {
        $full = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $item))
        if (Test-Path -LiteralPath $full) {
            $backup = Join-Path $TempRoot ("ventivoice-backup-" + [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetRandomFileName()) + "-" + (Split-Path $item -Leaf))
            $map[$item] = [pscustomobject]@{
                Source = $full
                Backup = $backup
            }
        }
    }
    return $map
}

function Backup-UserData {
    param([hashtable]$Map)

    foreach ($entry in $Map.GetEnumerator()) {
        $source = $entry.Value.Source
        $backup = $entry.Value.Backup
        $backupDir = Split-Path -Parent $backup
        if (-not (Test-Path -LiteralPath $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $backup -Force
        Write-Host "保留备份: $source"
    }
}

function Restore-UserData {
    param([hashtable]$Map)

    foreach ($entry in $Map.GetEnumerator()) {
        $sourceRel = $entry.Key
        $backup = $entry.Value.Backup
        if (Test-Path -LiteralPath $backup) {
            $target = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $sourceRel))
            $targetDir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $backup -Destination $target -Force
            Write-Host "恢复保留数据: $target"
        }
    }
}

function Cleanup-BackupFiles {
    param([hashtable]$Map)

    foreach ($entry in $Map.GetEnumerator()) {
        Remove-Item -LiteralPath $entry.Value.Backup -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "VentiVoice Windows 卸载器"
Write-Host "项目目录: $ProjectRoot"
Write-Host ""
Write-Host "将删除整个项目目录中的源码、README、脚本、模型、虚拟环境和运行时生成内容。"
Write-Host "可选择保留: config.yaml, corpus\corrections.json, corpus\blacklist.json"

if (-not $Force) {
    $confirm = Read-Host "确认完全卸载? 输入 y 继续"
    if ($confirm -notmatch "^(y|Y)$") {
        Write-Host "已取消。"
        exit 0
    }

    $keepChoice = Read-Host "是否保留配置和词库? [y/N]"
    if ($keepChoice -match "^(y|Y)$") {
        $KeepUserData = $true
    }
}

Write-Step "停止相关进程"
Stop-VentiVoiceProcesses

$backupMap = @{}
if ($KeepUserData) {
    Write-Step "备份用户数据"
    $backupMap = Get-BackupMap
    if ($backupMap.Count -gt 0) {
        Backup-UserData -Map $backupMap
    } else {
        Write-Warn "没有找到可保留的数据。"
    }
}

Write-Step "删除项目内容"
foreach ($child in Get-ChildItem -LiteralPath $ProjectRoot -Force) {
    $relativePath = Get-RelativeProjectPath -Path $child.FullName
    if ($relativePath -ieq "uninstall.bat") {
        continue
    }
    Remove-WithRetry -RelativePath $relativePath -Recurse:$child.PSIsContainer
}

Write-Step "删除桌面快捷方式"
$desktop = [Environment]::GetFolderPath("Desktop")
Remove-Shortcut (Join-Path $desktop "VentiVoice.lnk")

if ($KeepUserData) {
    Write-Step "恢复保留数据"
    Restore-UserData -Map $backupMap
    Cleanup-BackupFiles -Map $backupMap
}

Write-Step "清理空目录"
foreach ($dir in @("corpus", "models", "prompts", "scripts", "src")) {
    $fullDir = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $dir))
    if ((Test-Path -LiteralPath $fullDir) -and -not (Get-ChildItem -LiteralPath $fullDir -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $fullDir -Force -ErrorAction SilentlyContinue
    }
}

if (-not $KeepUserData) {
    $remainingBatch = Join-Path $ProjectRoot "uninstall.bat"
    if (Test-Path -LiteralPath $remainingBatch) {
        Start-DelayedCleanup -Paths @($ProjectRoot)
        Write-Warn "项目目录会在卸载窗口关闭后自动清理；如果仍被其他窗口占用，请稍后手动删除。"
    } else {
        try {
            Set-Location $TempRoot
            Remove-Item -LiteralPath $ProjectRoot -Recurse -Force -ErrorAction Stop
            Write-Ok "项目目录已删除。"
        } catch {
            Start-DelayedCleanup -Paths @($ProjectRoot)
            Write-Warn "项目目录会在卸载窗口关闭后自动清理；如果仍被其他窗口占用，请稍后手动删除。"
        }
    }
} else {
    Start-DelayedCleanup -Paths @((Join-Path $ProjectRoot "uninstall.bat"))
    Write-Ok "已删除程序文件，保留了用户数据。"
}

Write-Host ""
Write-Ok "卸载完成。"
