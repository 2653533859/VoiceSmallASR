# vsasr_app

VoiceSmallASR 的三端图形界面（Windows / macOS / Android）：本地离线的多语种语音识别与字幕。

与仓库根目录的 Python 端**同模型、同 sherpa-onnx 版本（1.13.5）**，因此识别结果应逐字一致 ——
Python 端是本端的对照基准。整体规划、阶段划分与踩坑记录见上一级目录的
[DEVELOPMENT_PLAN.md](../DEVELOPMENT_PLAN.md)。

## 当前进度

| 层 | 状态 |
| --- | --- |
| 引擎层（`lib/src/asr/`） | ✅ 已移植，与 Python 端一一对应（含 VAD 驱动的流式识别） |
| 音频解码（`lib/src/audio/`） | ✅ Dart 侧完成；macOS、Android API 35 模拟器和 Windows CI 已端到端验证，Android 真机与 Windows 用户桌面仍待实测 |
| 麦克风采集（`lib/src/audio/microphone.dart`） | ✅ `record` 取 16 kHz 单声道 PCM16 → float32 |
| 后台识别 isolate（`lib/src/asr/transcription_worker.dart`） | ✅ 整段转写 + 实时会话两条通道 |
| 字幕导入/导出（`lib/src/subtitles/`） | ✅ SRT/VTT/JSON 导入，SRT/VTT/JSON/TXT 导出，含双语字幕 |
| 翻译层（`lib/src/translation/`） | ✅ 第三方 OpenAI-compatible provider、批量/重试/进度、批量文件翻译复用 provider、双语导出、目标语言持久化、术语表、服务商预设、API 连接测试、文件/实时/视频字幕翻译已完成；真实网络验收按个人使用范围主动跳过 |
| 界面（`lib/src/ui/`） | ✅ M1、M2、M3、M5、M11、M12 完成，M13 字幕批量时间偏移、搜索替换、阅读速度检查、翻译术语表、服务商预设、播放器字幕样式、视频配套字幕导出、文件转写性能诊断、批量/实时性能汇总、持续性能历史以及手工说话人标签已完成：文件转写、实时字幕、视频播放、字幕联动、外部字幕加载、批量转写/翻译/导出、批量队列恢复、字幕校对编辑、项目保存/打开/最近项目 |

## 开发

```bash
# 国内先配 SDK 镜像：storage.googleapis.com 实测约 100 KB/s，腾讯云约 8 MB/s
export FLUTTER_STORAGE_BASE_URL=https://mirrors.cloud.tencent.com/flutter

flutter pub get
flutter analyze     # 验收标准：No issues found
flutter test        # 227 项，不依赖模型与设备

# Android release 构建（需要 Android SDK/JDK；当前 release 使用 debug signing 做验证）
flutter build apk --release
flutter build appbundle --release

# 真实 DeepL 英/日视频验收（密钥文件必须放在仓库外；不会进入默认测试集）
flutter test integration_test/deepl_acceptance_test.dart -d macos \
  --dart-define-from-file=/path/to/voicesmallasr-deepl.env

# macOS 无签名 Release .app/.dmg（从仓库根目录执行；发布签名仍需证书）
FLUTTER_BIN=/path/to/flutter/bin/flutter ./scripts/build_macos_unsigned.sh

# 端到端验收（真模型 + 真引擎 + 真原生解码，需 macOS；素材放法见上一级 DEVELOPMENT_PLAN §7）
flutter test integration_test/e2e_test.dart -d macos
```

不要设 `PUB_HOSTED_URL`：pub.dev 可直连，指向镜像会把 `pubspec.lock` 里所有包的 `url`
改写成镜像地址并重新解析依赖，那样的 lock 不应提交。

构建/运行各平台的前置条件：macOS 需 Xcode + CocoaPods（media_kit 的 macOS 插件当前不支持 Swift Package Manager；
本机已装；无签名模式的 Xcode 构建通过，Keychain Sharing 不可用时 API Key 会退回当前会话存储）；
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
