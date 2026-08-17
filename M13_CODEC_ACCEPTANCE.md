# M13 编解码器矩阵验收记录

## 本机 API 35 模拟器结果

2026-08-18 在 Android 15 / API 35 ARM64 `sdk_gphone64_arm64` 模拟器
（设备 ID：`emulator-5554`）上，使用同一个
`app/integration_test/hard_subtitle_acceptance_test.dart` 集成测试进程依次验收：

| 输入视频 | 音频处理 | 结果 |
| --- | --- | --- |
| H.264 + AAC / MP4 | AAC 音轨直通 | 通过 |
| H.264 + MP3 / MP4 | MP3 解码后转 AAC | 通过 |
| VP9 + Opus / WebM | VP9 解码，Opus 解码后转 AAC | 通过 |
| HEVC + AAC / MP4 | HEVC 解码，AAC 音轨直通 | 通过 |

输入文件先复制到模拟器的 `/data/local/tmp/`，确保应用可以直接读取；输出文件由
Android `MediaCodec + OpenGL + MediaMuxer` 生成到应用临时目录。四个输出均成功生成且
大于 1 KiB。

## 可复用命令

为避免 Android 集成测试依赖 shell 环境变量，使用 `--dart-define` 传入 `|` 分隔的输入路径：

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$PATH"

cd app
flutter test integration_test/hard_subtitle_acceptance_test.dart \
  -d emulator-5554 \
  '--dart-define=VSASR_HARD_SUBTITLE_TEST_VIDEOS=/data/local/tmp/aac.mp4|/data/local/tmp/mp3.mp4|/data/local/tmp/vp9-opus.webm|/data/local/tmp/hevc-aac.mp4'
```

仍兼容原有的单输入 `VSASR_HARD_SUBTITLE_TEST_VIDEO`。桌面端同样可以使用多输入变量；桌面
编码需要带 `ASS/libass` 滤镜的 FFmpeg。

## 范围限制

这次矩阵只证明 API 35 ARM64 模拟器上的系统编解码器路径，不替代 Android 真机性能和厂商
Codec 差异验收；普通 macOS FFmpeg 8.1.1 不含 `libass`，仍不能作为桌面硬字幕验收环境。
