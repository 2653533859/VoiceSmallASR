# vsasr_app

VoiceSmallASR 的三端图形界面（Windows / macOS / Android）：本地离线的多语种语音识别与字幕。

与仓库根目录的 Python 端**同模型、同 sherpa-onnx 版本（1.13.5）**，因此识别结果应逐字一致 ——
Python 端是本端的对照基准。整体规划、阶段划分与踩坑记录见上一级目录的
[DEVELOPMENT_PLAN.md](../DEVELOPMENT_PLAN.md)。

## 当前进度

| 层 | 状态 |
| --- | --- |
| 引擎层（`lib/src/asr/`） | ✅ 已移植，与 Python 端一一对应（含 VAD 驱动的流式识别） |
| 音频解码（`lib/src/audio/`） | ✅ Dart 侧完成；macOS 原生解码已编译，Android/Windows 已写但未编译 |
| 麦克风采集（`lib/src/audio/microphone.dart`） | ✅ `record` 取 16 kHz 单声道 PCM16 → float32 |
| 后台识别 isolate（`lib/src/asr/transcription_worker.dart`） | ✅ 整段转写 + 实时会话两条通道 |
| 字幕导出（`lib/src/subtitles/`） | ✅ 含双语字幕 |
| 翻译层（`lib/src/translation/`） | 🚧 M4 基础抽象、批量/重试/进度、双语导出、DeepL provider 与文件转写页翻译入口已完成；M6 设置页、模型管理与离线模式已接入，真实网络验收待完成 |
| 界面（`lib/src/ui/`） | ✅ M1、M2、M3、M5 完成：文件转写、实时字幕、视频播放、字幕联动、字幕校对编辑 |

## 开发

```bash
# 国内先配 SDK 镜像：storage.googleapis.com 实测约 100 KB/s，腾讯云约 8 MB/s
export FLUTTER_STORAGE_BASE_URL=https://mirrors.cloud.tencent.com/flutter

flutter pub get
flutter analyze     # 验收标准：No issues found
flutter test        # 149 项，不依赖模型与设备

# 端到端验收（真模型 + 真引擎 + 真原生解码，需 macOS；素材放法见上一级 DEVELOPMENT_PLAN §7）
flutter test integration_test/e2e_test.dart -d macos
```

不要设 `PUB_HOSTED_URL`：pub.dev 可直连，指向镜像会把 `pubspec.lock` 里所有包的 `url`
改写成镜像地址并重新解析依赖，那样的 lock 不应提交。

构建/运行各平台的前置条件：macOS 需 Xcode + CocoaPods（media_kit 的 macOS 插件当前不支持 Swift Package Manager；
本机已装；无签名模式的 Xcode 构建通过，带 Keychain Sharing 的 `flutter build macos --debug` 需要开发证书）；
Windows 需开发者模式 + Visual Studio C++ 工具链；
Android 需真机或模拟器。

## 分层约定

`sherpa_onnx` 的原生类型只出现在 `lib/src/asr/asr_engine.dart` 与 `vad_session.dart` 里，
其余各层（界面、字幕、翻译）只接触 `Segment` / `TranscriptionResult` 这类纯数据对象。
持有原生指针的对象必须手动 `free()`，都收在各自的 `dispose()` 中。

## 原生音频解码

压缩格式与视频走 `vsasr/audio_decoder` 通道：方法 `decodeToPcm16k`，入参 `{'path': String}`，
回 16 kHz 单声道 float32（`Float32List` 或小端字节流都接受）。三端实现：

| 平台 | 文件 | API |
| --- | --- | --- |
| macOS | `macos/Runner/MainFlutterWindow.swift` | `AVAssetReader` + `AVAssetReaderAudioMixOutput` |
| Android | `android/app/src/main/kotlin/com/voicesmallasr/vsasr_app/MainActivity.kt` | `MediaExtractor` + `MediaCodec` |
| Windows | `windows/runner/audio_decoder.cpp` | Media Foundation `IMFSourceReader` |

wav 不走这条路 —— 纯 Dart 直读，因此可以单测。非 16 kHz 素材的线性重采样在
`wav.dart`、Kotlin、C++ 里各有一份，三者逐行等价，改一处要同步另两处。

## 麦克风与权限

实时字幕用 `record` 取流，权限走它自带的 `hasPermission()`（会发起运行时申请），
没有引入 `permission_handler`。各平台还需要的声明：

| 平台 | 需要什么 |
| --- | --- |
| macOS | `Info.plist` 的 `NSMicrophoneUsageDescription`（**缺了是闪退，不是弹框**）+ 两个 entitlements 里的 `device.audio-input` |
| Android | `AndroidManifest.xml` 的 `RECORD_AUDIO` |
| Windows | 无额外声明 |
