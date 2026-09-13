# vsasr_app

VoiceSmallASR 的三端图形界面（Windows / macOS / Android）：本地离线的多语种语音识别与字幕。

与仓库根目录的 Python 端**同模型、同 sherpa-onnx 版本（1.13.5）**，因此识别结果应逐字一致 ——
Python 端是本端的对照基准。整体规划、阶段划分与踩坑记录见上一级目录的
[DEVELOPMENT_PLAN.md](../DEVELOPMENT_PLAN.md)。

## 当前进度

2026-09-12 工作树完成视频字幕策略、可恢复文件夹批量任务和字幕质量/格式三轮改进，并补充视频画面旋转和后台任务中心；普通文件/WAV 增量转写、资源诊断、实时过载及有界收尾继续保留。当前交付与剩余真实设备验收见 [三轮改进记录](../THREE_ROUND_IMPROVEMENTS.md)。

| 层 | 状态 |
| --- | --- |
| 引擎层（`lib/src/asr/`） | ✅ 已移植，与 Python 端一一对应（含 VAD 驱动的流式识别） |
| 音频解码（`lib/src/audio/`） | ✅ Dart 侧完成；macOS、Android API 35 模拟器和 Windows CI 已端到端验证，Android 真机与 Windows 用户桌面仍待实测 |
| 麦克风采集（`lib/src/audio/microphone.dart`） | ✅ `record` 取 16 kHz 单声道 PCM16 → float32 |
| 后台识别 isolate（`lib/src/asr/transcription_worker.dart`） | ✅ 整段转写 + 实时会话两条通道；由 worker 池按调度容量复用 |
| 字幕导入/导出（`lib/src/subtitles/`） | ✅ SRT/VTT/JSON 导入，SRT/VTT/JSON/TXT 导出，含双语字幕 |
| 翻译层（`lib/src/translation/`） | ✅ 第三方 OpenAI-compatible provider、模型列表获取与选择、批量/重试/进度、批量文件翻译复用 provider、双语导出、目标语言持久化、术语表、服务商预设、API 连接测试、文件/实时/视频字幕翻译已完成；真实网络验收按个人使用范围主动跳过 |
| 界面（`lib/src/ui/`） | ✅ 文件转写、实时字幕、视频播放、字幕联动、外部字幕加载、批量转写/翻译/导出、字幕校对和项目管理已完成；视频页新增播放列表、播放时流式转写、非中文字幕逐段翻译、字幕/翻译开关以及后续视频字幕预缓存；主窗口提供后台任务中心 |

## 后台任务中心

主窗口右上角的任务中心会显示活动任务数量。打开后可统一查看当前文件识别、普通批量队列、实时字幕、视频逐句翻译、硬字幕编码、文件夹自动处理、识别 worker 占用和等待队列，并可取消当前文件或视频翻译任务、暂停或取消批量任务、停止实时字幕以及进入批量详情处理失败条目。

文件夹处理控制器由首页持有，处理期间可返回主界面继续使用设置和播放器，再从任务中心查看状态或暂停。硬字幕编码器当前没有安全中止接口，因此任务中心只显示编码进度。任务中心不会保存字幕文本或 API Key。

任务中心还会在当前会话中保留最近 10 条视频翻译、硬字幕编码和文件夹处理失败记录。记录只包含时间、任务类型、文件名和脱敏摘要；完整路径、网络地址、Bearer 凭据及 API Key 会在显示前清理，可随时点击「清除记录」。

## 字幕锚点校时

在「校对字幕」工具栏点击「按锚点校时」，选择一条时间准确的字幕并输入它实际应出现的开始时间。编辑器会计算偏移量并整体移动所有字幕，同时保留相对间隔、显示时长、译文和 token 时间戳。对齐结果可撤销；如果移动后超出媒体时间范围，操作会被拒绝且不改变字幕。

代码中还包含实验性的 VAD 分段校时建议器。它只在字幕数量与语音活动区间一致、所有边界移动不超过阈值、结果无重叠且位于媒体时长内时返回建议，目前尚未开放界面入口。自然语音出现漏检或多检时会拒绝建议，避免自动改坏字幕。

## 文件夹顺序转写与翻译

从「批量处理 → 文件夹自动处理」选择文件夹，预览队列后点击「开始 / 继续」。仅扫描当前层的视频与音频，按自然文件名顺序（1、2、10）逐个完成转写、翻译和保存，再处理下一文件。

- 默认自动翻译，沿用设置中的翻译服务与目标语言；关闭「转写后自动翻译」则仅生成原文字幕。识别沿用当前语言与语音检测设置。
- 默认保存为媒体旁的同名 `.srt`；也可选择独立输出文件夹以及 SRT/VTT/JSON/TXT 格式。开启翻译时输出双语字幕，关闭时只输出原文。
- 已有同名 SRT/VTT/ASS/SSA 的媒体会跳过，也识别 `.ja.srt`、`.zh-CN.srt`、`.bilingual.srt` 等后缀；开始前和保存前再次检查，保留已有字幕。此检查针对外部字幕文件，不检查视频内嵌字幕轨。
- 单个文件失败会继续下一个；可将失败项单独重新排队，并按等待、失败、完成或跳过状态筛选。未识别到语音或翻译失败时不生成字幕文件。
- 「完成当前文件后暂停」会等待当前文件保存后暂停，之后可以继续。队列和输出选项保存在应用私有目录，应用退出或离开页面后重新进入可恢复未完成任务。
- 独立输出目录中出现重名时可选择跳过或自动追加编号；写入始终使用独占创建，失败会删除本次半成品，不覆盖已有文件。
- 可为整批设置自动检测、中文、英文、日文、韩文或粤语，并为单个等待项覆盖语言；识别结果中的语言标签与指定语言不一致时会提示检查原文。

## 日语识别与小声语音

在设置中将「识别语言（原音频）」设为「日文」，保存后重新转写日语素材；混合语言可保留自动检测。翻译目标语言只控制译文，检查原文识别时可切换为仅原文。

小声容易漏识别时，可点击「应用小声语音预设」：语音检测阈值 0.35、句末静音 0.50 秒、最短语音 0.15 秒、输入增益 +6 dB。保存后重新转写，文件、视频和实时识别均使用这些参数。预设不会更改识别语言。

输入增益可在 0–12 dB 间调整，默认关闭，在语音检测之前生效且不改变原文件和播放音量。增益也会放大噪声，过高可能造成限幅失真；可使用「恢复标准语音参数」恢复默认检测参数和 0 dB 增益。修改增益会使已有识别缓存失效。

已使用本地日语模型对音量减半的日语样本验证整段与流式识别，均输出日文。此验证覆盖参数通路，不代表真实低声或嘈杂录音的准确率评测。

```bash
VSASR_MODEL_DIR=/path/to/models flutter test integration_test/quiet_speech_acceptance_test.dart -d macos --no-pub
```

## 视频文件夹播放

视频播放页点击「选择文件夹」，将当前层支持的视频按自然文件名顺序（1、2、10）加入播放列表，自动去重；不扫描子目录。空列表会打开首个视频，已有列表则追加，沿用现有顺序播放和字幕处理流程。取消选择不改变列表。

播放页每次进入默认只播放视频，不自动加载字幕或翻译，也不沿用上次开启的状态。字幕策略分为「关闭」「仅加载已有字幕」「缺失时自动识别」：仅加载模式只读取同名 SRT 或有效缓存，没有字幕时不会启动识别；自动识别模式才会处理缺少字幕的视频。开启「自动翻译」才调用翻译服务，关闭字幕会停止后台处理并关闭翻译。字幕工具仍支持手动选择外部字幕文件。

开启字幕后，播放页优先加载视频旁的 SRT/VTT/ASS/SSA 配套字幕并跳过识别，包括 `.ja.srt`、`.zh-CN.vtt` 等语言后缀；同名文件优先于语言后缀，同级按 SRT、VTT、ASS、SSA 选择。原字幕不被改写；读取失败会提示错误并继续下一项。当前会话中已有字幕编辑保持不变。

视频内嵌字幕默认关闭。检测到内嵌字幕轨后，可从「字幕工具 → 选择内嵌字幕轨」按标题和语言选择；选择内嵌轨会关闭应用生成的字幕层，重新开启应用字幕时也会关闭内嵌轨，避免双层字幕。

可用带内嵌字幕的本地视频验证真实播放器轨道枚举与切换：

```bash
VSASR_EMBEDDED_SUBTITLE_VIDEO=/path/to/video.mkv \
  flutter test integration_test/embedded_subtitle_acceptance_test.dart -d macos
```

播放列表改为纵向列表，宽窗口显示在右侧，小窗口点击「播放列表」打开。支持拖动排序、当前项高亮、完整文件名提示、字幕来源/处理状态和移除条目。顶部工具栏将视频文件与文件夹入口合并到「添加」，缓存操作收进「更多」。

播放页「更多 → 顺时针旋转 90°」可循环切换 0°、90°、180° 和 270°。旋转只作用于视频画面，字幕、播放控制和时间轴保持正常方向；90° 与 270° 会交换画面布局尺寸以适配播放区域。


## 视频键盘跳转

视频页左右方向键分别后退/前进 10 秒。连续按键基于上次目标位置累加；跳转串行执行，并合并等待中的目标，避免旧播放位置导致按键失效或请求堆积。进度条先显示目标位置，后端确认后恢复实际播放进度；跳转失败或确认超时会回到后端报告的位置。播放列表仅依据后端实际进度判断结束，跳转未确认时不自动切换下一项。

## 音频波形与字幕时间轴

加载媒体后，在 Studio 工具栏点击「波形时间轴」（小窗口工具栏可横向滚动）。波形只加载当前可见的 15/30/60/120 秒窗口，前后翻页或「定位到播放位置」可切换范围，不一次保留整部视频音频。波形为原始音量峰值，不应用识别增益。

- 点击波形定位播放；在波形上拖动选择区间。
- 点击「循环播放选区」反复播放，关闭时间轴会结束循环模式。
- 点击「选区重新识别」将起止时间带入参数与预览对话框，确认前不改字幕。
- 拖动字幕块两侧手柄调整边界，松手时提交一次编辑；重叠或越界会拒绝。字幕太短时可缩小时间窗口再操作。
- 关闭时间轴后可在 Studio 撤销/重做边界修改。时间变化会清除失效的词级时间戳。

打开时间轴时会暂时挂起视频监视器的单句循环，避免两套循环互相跳转。波形加载失败可重试，切换窗口或关闭后会丢弃迟到结果并结束旧解码流。

## 选区重新识别

在 Studio 工具栏点击「选区重新识别」，输入开始/结束秒数（默认从播放位置开始），可单独调整原音频语言、输入增益、语音检测阈值，或应用小声语音预设。单次范围最多 120 秒；范围碰到已有字幕时自动扩展到完整字幕边界，实际范围会在识别前显示。也可选择没有字幕的间隙来补漏。已加载对应媒体时使用其真实时长，因此可以补识别导入字幕末尾之后的语音；确认替换会同时更新结果时长，撤销可恢复。

点击「识别并预览」查看原字幕与新字幕，再点击「确认替换」。只有选区内字幕会更新，替换作为一次操作接入撤销/重做，项目保存和导出沿用当前编辑结果。新字幕清除旧译文及说话人标签，需重新翻译或标注；区外字幕保持不变。

本次识别参数不写入全局设置。识别失败、无语音或取消时保留原字幕；取消后会丢弃迟到结果，正在进行的模型调用可能需要收尾。需要有本地媒体路径，纯字幕文件需先关联媒体。解码从选区起点开始，到选区结束即关闭解码流。

Studio 的「字幕质量检查」会汇总阅读过快、长空白、连续重复文本、疑似语言错误，以及时间重叠和空文本。点击问题定位播放位置；点击问题右侧的重新识别按钮会把对应字幕或空白范围带入选区重新识别对话框，确认替换后仍可撤销。

```bash
# 真实 MP4 验收：素材至少 8 秒，1–8 秒含日语语音
VSASR_MODEL_DIR=/path/to/models VSASR_RANGE_VIDEO=/path/to/ja.mp4 \
  flutter test integration_test/range_retranscription_acceptance_test.dart -d macos --no-pub
```

## 本地素材验收

本次结果见 [本地素材验收记录](../LOCAL_MEDIA_ACCEPTANCE.md)。

可使用超过 10 分钟、24–45 秒含日语语音的视频，验证真实播放器的暂停/播放中跳转、选区参数对比和撤销。测试静音并隐藏视频画面，只输出时间、段数和语言标签等指标，不保存识别文本。自动语言和指定语言的结果对比不等同于人工准确率评测。

```bash
VSASR_MODEL_DIR=/path/to/models VSASR_LOCAL_VIDEO=/path/to/video.ts \
  flutter test integration_test/local_media_acceptance_test.dart -d macos --no-pub
```

## 开发

```bash
# 国内先配 SDK 镜像：storage.googleapis.com 实测约 100 KB/s，腾讯云约 8 MB/s
export FLUTTER_STORAGE_BASE_URL=https://mirrors.cloud.tencent.com/flutter

flutter pub get
flutter analyze     # 验收标准：No issues found
flutter test        # 411 项，不依赖模型与设备（2026-09-13）

# Android release 构建（需要 Android SDK/JDK；当前 release 使用 debug signing 做验证）
flutter build apk --release
flutter build appbundle --release

# 可选：真实第三方 OpenAI-compatible API 英/日视频验收（密钥文件必须放在仓库外）
flutter test integration_test/api_translation_acceptance_test.dart -d macos \
  --dart-define-from-file=/path/to/voicesmallasr-api.env.json

# macOS 无开发者证书 Release .app/.dmg（从仓库根目录执行；内嵌代码使用 ad-hoc 签名）
FLUTTER_BIN=/path/to/flutter/bin/flutter ./scripts/build_macos_unsigned.sh

# 端到端验收（真模型 + 真引擎 + 真原生解码，需 macOS；素材放法见上一级 DEVELOPMENT_PLAN §7）
flutter test integration_test/e2e_test.dart -d macos
```

不要设 `PUB_HOSTED_URL`：pub.dev 可直连，指向镜像会把 `pubspec.lock` 里所有包的 `url`
改写成镜像地址并重新解析依赖，那样的 lock 不应提交。

构建/运行各平台的前置条件：macOS 需 Xcode + CocoaPods（media_kit 的 macOS 插件当前不支持 Swift Package Manager；
本机已装；无开发者证书模式的 Xcode 构建通过，构建脚本会对嵌入 Framework 做 ad-hoc 签名，Keychain Sharing 不可用时 API Key 会退回当前会话存储）；
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
