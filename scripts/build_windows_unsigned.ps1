[CmdletBinding()]
param(
    [string]$Flutter = "flutter"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$appDir = Join-Path $repoRoot "app"
$releaseDir = Join-Path $appDir "build\windows\x64\runner\Release"
$outputDir = Join-Path $repoRoot "dist\windows"
$issFile = Join-Path $repoRoot "scripts\VoiceSmallASR.iss"

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
    Invoke-Checked -File $Flutter -Arguments @("build", "windows", "--release")
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
    "/O$outputDir",
    $issFile
)

Write-Host "Windows Release：$releaseDir"
Write-Host "Windows 安装包：$(Join-Path $outputDir 'VoiceSmallASR-unsigned-setup.exe')"
