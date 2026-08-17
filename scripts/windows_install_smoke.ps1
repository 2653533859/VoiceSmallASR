[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [int]$StartupWaitSeconds = 8
)

$ErrorActionPreference = "Stop"

$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$installPath = [System.IO.Path]::GetFullPath($InstallDir)

if (Test-Path -LiteralPath $installPath) {
    $existing = Get-Item -LiteralPath $installPath
    if (-not $existing.PSIsContainer) {
        throw "Windows 安装目标不是目录：$installPath"
    }
    if (@(Get-ChildItem -LiteralPath $installPath -Force).Count -gt 0) {
        throw "Windows 安装目标必须为空：$installPath"
    }
}
else {
    New-Item -ItemType Directory -Force -Path $installPath | Out-Null
}

$installerArguments = @(
    "/VERYSILENT",
    "/SUPPRESSMSGBOXES",
    "/NORESTART",
    "/SP-",
    "/DIR=`"$installPath`""
)
$installerProcess = Start-Process -FilePath $installerPath -ArgumentList $installerArguments -Wait -PassThru
if ($installerProcess.ExitCode -ne 0) {
    throw "Windows 安装包执行失败，退出码 $($installerProcess.ExitCode)"
}

$exePath = Join-Path $installPath "vsasr_app.exe"
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "安装后缺少应用可执行文件：$exePath"
}

$requiredFiles = @(
    "flutter_windows.dll",
    "libmpv-2.dll",
    "onnxruntime.dll",
    "sherpa-onnx-c-api.dll"
)
foreach ($requiredFile in $requiredFiles) {
    $path = Join-Path $installPath $requiredFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "安装后缺少运行时依赖：$path"
    }
}

$forbiddenFiles = Get-ChildItem -LiteralPath $installPath -Recurse -File |
    Where-Object {
        $_.Name -match '(?i)(\.onnx|\.tar|\.bz2)$' -or $_.Name -ieq "tokens.txt"
    }
if ($forbiddenFiles) {
    $paths = ($forbiddenFiles | ForEach-Object { $_.FullName }) -join "; "
    throw "安装目录误包含模型文件：$paths"
}

$cleanProfile = Join-Path (Split-Path -Parent $installPath) "voicesmallasr-windows-clean-profile"
New-Item -ItemType Directory -Force -Path $cleanProfile | Out-Null
$previousAppData = $env:APPDATA
$previousLocalAppData = $env:LOCALAPPDATA
$process = $null
try {
    # 为首次启动提供隔离的用户数据环境，避免复用 runner 上已有的应用配置。
    $env:APPDATA = $cleanProfile
    $env:LOCALAPPDATA = $cleanProfile
    $process = Start-Process -FilePath $exePath -WorkingDirectory $installPath -PassThru
    Start-Sleep -Seconds $StartupWaitSeconds
    $process.Refresh()
    if ($process.HasExited) {
        throw "安装后的应用首次启动后立即退出，退出码 $($process.ExitCode)"
    }
    Write-Host "Windows 安装包已实际安装并保持运行 ${StartupWaitSeconds}s，首次启动通过"
}
finally {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
        }
    }
    if ($null -eq $previousAppData) {
        Remove-Item Env:APPDATA -ErrorAction SilentlyContinue
    }
    else {
        $env:APPDATA = $previousAppData
    }
    if ($null -eq $previousLocalAppData) {
        Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue
    }
    else {
        $env:LOCALAPPDATA = $previousLocalAppData
    }
}
