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
$baseUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
$archivePath = Join-Path $temporaryRoot $archiveName

New-Item -ItemType Directory -Force -Path $ModelRoot | Out-Null
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    Invoke-WebRequest -Uri "$baseUrl/$archiveName" -OutFile $archivePath
}

$asrDir = Join-Path $ModelRoot $modelName
$asrModel = Join-Path $asrDir "model.int8.onnx"
$tokens = Join-Path $asrDir "tokens.txt"
if (-not (Test-Path -LiteralPath $asrModel -PathType Leaf) -or
    -not (Test-Path -LiteralPath $tokens -PathType Leaf)) {
    tar -xjf $archivePath -C $ModelRoot
    if ($LASTEXITCODE -ne 0) {
        throw "模型压缩包解压失败，退出码 $LASTEXITCODE"
    }
}

$vadPath = Join-Path $ModelRoot "silero_vad.onnx"
if (-not (Test-Path -LiteralPath $vadPath -PathType Leaf)) {
    Invoke-WebRequest -Uri "$baseUrl/silero_vad.onnx" -OutFile $vadPath
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
& ffmpeg -y -i $yueWav -c:a aac -b:a 128k $yueM4a
if ($LASTEXITCODE -ne 0) {
    throw "生成 yue.m4a 失败，退出码 $LASTEXITCODE"
}
& ffmpeg -y -f lavfi -i "color=c=black:s=640x360:r=30:d=8" -i $enWav `
    -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest $enMp4
if ($LASTEXITCODE -ne 0) {
    throw "生成 en.mp4 失败，退出码 $LASTEXITCODE"
}

Write-Host "Windows e2e 模型与媒体已准备：$ModelRoot"
