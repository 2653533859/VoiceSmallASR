[CmdletBinding()]
param(
    [string]$ModelRoot = ""
)

$ErrorActionPreference = "Stop"

$temporaryRoot = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $env:TEMP
} else {
    $env:RUNNER_TEMP
}
if ([string]::IsNullOrWhiteSpace($ModelRoot)) {
    $ModelRoot = Join-Path $temporaryRoot "voicesmallasr-models"
}

$modelName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
$archiveName = "$modelName.tar.bz2"
$baseUrls = @(
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models",
    "https://ghfast.top/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models",
    "https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
)
$archiveMinBytes = 100MB
$vadMinBytes = 512KB
$archivePath = Join-Path $temporaryRoot $archiveName
$asrDir = Join-Path $ModelRoot $modelName
$asrModel = Join-Path $asrDir "model.int8.onnx"
$tokens = Join-Path $asrDir "tokens.txt"
$vadPath = Join-Path $ModelRoot "silero_vad.onnx"

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "Windows runner 缺少 curl.exe，无法准备模型"
}

New-Item -ItemType Directory -Force -Path $ModelRoot | Out-Null

function Download-ModelFile {
    param(
        [string]$FileName,
        [string]$Destination,
        [long]$MinimumBytes
    )

    foreach ($baseUrl in $baseUrls) {
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            Remove-Item -LiteralPath $Destination -Force
        }
        $url = "$baseUrl/$FileName"
        Write-Host "下载模型文件：$url"
        & curl.exe --fail --location --retry 1 --retry-all-errors --retry-delay 5 `
            --connect-timeout 30 --speed-limit 262144 --speed-time 60 `
            --retry-max-time 600 --max-time 900 --output $Destination $url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            $length = (Get-Item -LiteralPath $Destination).Length
            if ($length -ge $MinimumBytes) {
                Write-Host "下载完成：$Destination ($length bytes)"
                return
            }
            Write-Warning "文件过短（$length bytes），切换下一个源：$url"
        } else {
            Write-Warning "下载失败，切换下一个源：$url"
        }
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            Remove-Item -LiteralPath $Destination -Force
        }
    }
    throw "$FileName 下载失败：所有模型源均不可用"
}

if (-not (Test-Path -LiteralPath $asrModel -PathType Leaf) -or
    -not (Test-Path -LiteralPath $tokens -PathType Leaf)) {
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        (Get-Item -LiteralPath $archivePath).Length -lt $archiveMinBytes) {
        Download-ModelFile -FileName $archiveName -Destination $archivePath -MinimumBytes $archiveMinBytes
    }
    if (Test-Path -LiteralPath $asrDir) {
        Remove-Item -LiteralPath $asrDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $ModelRoot | Out-Null
    & tar -xjf $archivePath -C $ModelRoot
    if ($LASTEXITCODE -ne 0) {
        throw "模型压缩包解压失败，退出码 $LASTEXITCODE"
    }
}

if (-not (Test-Path -LiteralPath $vadPath -PathType Leaf) -or
    (Get-Item -LiteralPath $vadPath).Length -lt $vadMinBytes) {
    Download-ModelFile -FileName "silero_vad.onnx" -Destination $vadPath -MinimumBytes $vadMinBytes
}

$wavs = Join-Path $asrDir "test_wavs"
$yueWav = Join-Path $wavs "yue.wav"
$enWav = Join-Path $wavs "en.wav"
if (-not (Test-Path -LiteralPath $yueWav -PathType Leaf) -or
    -not (Test-Path -LiteralPath $enWav -PathType Leaf)) {
    throw "模型压缩包缺少 e2e 测试音频：$wavs"
}

$yueM4a = Join-Path $wavs "yue.m4a"
$enMp4 = Join-Path $wavs "en.mp4"
if (-not (Test-Path -LiteralPath $yueM4a -PathType Leaf)) {
    & ffmpeg -hide_banner -loglevel error -y -i $yueWav -c:a aac -b:a 128k $yueM4a
    if ($LASTEXITCODE -ne 0) {
        throw "生成 yue.m4a 失败，退出码 $LASTEXITCODE"
    }
}
if (-not (Test-Path -LiteralPath $enMp4 -PathType Leaf)) {
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=black:s=640x360:r=30:d=8" `
        -i $enWav -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest $enMp4
    if ($LASTEXITCODE -ne 0) {
        throw "生成 en.mp4 失败，退出码 $LASTEXITCODE"
    }
}

Write-Host "Windows e2e 模型与媒体已准备：$ModelRoot"
