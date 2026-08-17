[CmdletBinding()]
param(
    [string]$Flutter = "flutter",
    [string]$BuildName = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$appDir = Join-Path $repoRoot "app"
$releaseDir = Join-Path $appDir "build\windows\x64\runner\Release"
$outputDir = Join-Path $repoRoot "dist\windows"
$issFile = Join-Path $repoRoot "scripts\VoiceSmallASR.iss"

if ([string]::IsNullOrWhiteSpace($BuildName)) {
    $pubspec = Get-Content (Join-Path $appDir "pubspec.yaml") -Raw
    $match = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)')
    if (-not $match.Success) {
        throw "无法从 app/pubspec.yaml 读取应用版本"
    }
    $BuildName = $match.Groups[1].Value
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @()
    )
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$File 执行失败，退出码 $LASTEXITCODE"
    }
}

Push-Location $appDir
try {
    Invoke-Checked -File $Flutter -Arguments @("pub", "get")
    Invoke-Checked -File $Flutter -Arguments @(
        "build", "windows", "--release", "--build-name", $BuildName
    )
}
finally {
    Pop-Location
}

$exe = Join-Path $releaseDir "vsasr_app.exe"
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Windows Release 可执行文件不存在：$exe"
}

$iscc = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
if (-not (Test-Path -LiteralPath $iscc -PathType Leaf)) {
    throw "找不到 Inno Setup 编译器：$iscc；请先安装 Inno Setup 6"
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
Invoke-Checked -File $iscc -Arguments @(
    "/DAppBuildDir=$releaseDir",
    "/DAppVersion=$BuildName",
    "/O$outputDir",
    $issFile
)

Write-Host "Windows Release：$releaseDir"
Write-Host "Windows 安装包：$(Join-Path $outputDir 'VoiceSmallASR-unsigned-setup.exe')"
