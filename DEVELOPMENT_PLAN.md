# VoiceSmallASR 后续开发计划

> 更新日期：2026-08-17　　当前版本：1.0.1

后续版本的稳定化、发布治理和产品功能计划见 [NEXT_DEVELOPMENT_PLAN.md](NEXT_DEVELOPMENT_PLAN.md)。

## 1. 现状速览

项目分两端，共用同一套模型与同一套业务语义：

| 端 | 技术栈 | 状态 | 用途 |
| --- | --- | --- | --- |
| **Python 端** | Python 3.11.4+ / sherpa-onnx 1.13.5 | ✅ 已完成，107 项测试通过 | CLI 工具、服务端集成、批处理 |
| **Flutter 端** | Flutter 3.47.0 / Dart 3.13.0 / sherpa_onnx 1.13.5 | 🚧 **M1、M2、M3、M5 已完成，M4 翻译基础、批量流程、双语导出、第三方 API provider、文件/实时/视频字幕翻译工作流已完成，M6 设置页与模型管理已完成首期实现，M7 已完成个人使用所需的三端安装包和 GitHub Release，M8 发布质量基线代码已落地，M9 无签名翻译体验已完成，M11 项目保存、字幕导入、首页项目管理、Android SAF、自动保存、异常恢复与媒体重新定位已完成，M12 多文件队列首项已完成**：文件转写、实时字幕、视频播放与字幕联动、外部字幕加载、批量转写队列、字幕校对编辑（186 项单测 + Android API 35 模拟器端到端 7 项，粤语识别 RTF 0.027 + Windows runner 端到端 7 项，粤语识别 RTF 0.064）。个人使用范围内剩余 Android 真机性能和 Windows 用户桌面运行验证；第三方 API 真实网络验收主动跳过，商店/公证发布证书不在个人使用范围 | Windows / macOS / Android 图形界面 |

两端用的是**同一个模型、同一个 sherpa-onnx 版本**（1.13.5），因此识别结果一致，Python 端可以作为 Flutter 端的对照基准。

### 已验证的能力（Python 端实测）

| 音频 | 时长 | 耗时 | RTF | 结果 |
| --- | --- | --- | --- | --- |
| zh | 5.59s | 0.20s | 0.035 | 开饭时间早上9点至下午5点。 |
| en | 7.15s | 0.24s | 0.033 | The tribal chieftain called for the boy. / And presented him with 50 pieces of gold. |
| ja | 7.20s | 0.23s | 0.032 | うちの中学は弁当制で持っていけない場合は五十円の学校販売のパンを買う。 |
| yue | 5.15s | 0.14s | 0.028 | 呢几个字都表达唔到，我想讲嘅意思。 |

粤语一行是选型的验证点：`呢`/`唔`/`嘅` 被保留，没有被转写成书面普通话。

## 2. 架构

```
VoiceSmallASR/
├── src/voice_small_asr/        Python 库 + CLI（已完成）
│   ├── config.py               ASRConfig / VADConfig
│   ├── models.py               模型下载、解压、缓存、就绪检查
│   ├── audio.py                加载/重采样（ffmpeg）/分块/麦克风
│   ├── vad.py                  silero-vad 封装
│   ├── engine.py               SenseVoice 解码 + 整段转写
│   ├── streaming.py            VAD 驱动的流式识别
│   ├── segments.py             Word / Segment / TranscriptionResult
│   ├── subtitles.py            SRT / VTT / JSON / TXT
│   └── cli.py                  download / transcribe / live / devices
├── app/                        Flutter 三端客户端
│   ├── lib/src/
│   │   ├── asr/
│   │   │   ├── asr_config.dart      ← 对应 config.py
│   │   │   ├── segment.dart         ← 对应 segments.py（多 translation 字段）
│   │   │   ├── model_manager.dart   ← 对应 models.py
│   │   │   ├── vad_session.dart     ← 对应 vad.py
│   │   │   ├── asr_engine.dart      ← 对应 engine.py
│   │   │   ├── streaming_transcriber.dart ← 对应 streaming.py
│   │   │   └── transcription_worker.dart  后台识别 isolate（Python 端无对应物）
│   │   ├── audio/
│   │   │   ├── wav.dart             ← 对应 audio.py 的 soundfile 直读路径（纯 Dart）
│   │   │   ├── microphone.dart      ← 对应 audio.py 的 iter_microphone（record 包）
│   │   │   └── audio_decoder.dart   ← 对应 audio.py 的 ffmpeg 路径（转给原生解码）
│   │   ├── subtitles/subtitles.dart ← 对应 subtitles.py（多双语字幕）
│   │   ├── video/                   media_kit 播放器与字幕时间轴
│   │   └── ui/                      界面层（Python 端对应物是 cli.py）
│   │       ├── app.dart             MaterialApp 外壳
│   │       ├── transcribe_controller.dart  状态机：模型→解码→识别→导出
│   │       ├── live_controller.dart 状态机：麦克风→识别→临时/定稿段
│   │       └── home_page.dart       下载页 / 两个页签 / 分段列表 / 导出对话框
│   ├── android/…/MainActivity.kt            原生解码（MediaExtractor + MediaCodec）
│   ├── macos/Runner/MainFlutterWindow.swift 原生解码（AVAssetReader）
│   └── windows/runner/audio_decoder.cpp     原生解码（IMFSourceReader）
├── examples/                   Python 集成示例
├── tests/                      Python 测试（107 项）
└── DEVELOPMENT_PLAN.md         本文档
```

分层原则：**sherpa-onnx / sherpa_onnx 的原生类型只出现在 `engine`/`vad` 层**，对外一律是 `Segment` / `TranscriptionResult` 这类纯数据对象。UI 层与翻译层都不感知推理框架。

## 3. 已完成

### Python 端（可用于生产）

- 整段转写、VAD 分段、批量解码，RTF ≈ 0.03
- 流式识别：临时结果 + 定稿双轨输出
- 段级 + token 级时间戳
- SRT / VTT / JSON / TXT 导出，长段按时间戳与时长上限切分
- 模型首次联网下载并缓存，之后完全离线；支持离线目录部署
- **模型下载三源 fallback**（GitHub → ghfast.top → gh-proxy.com），与 Flutter 端 `kModelBaseUrls`
  同源同序；任一源不通或返回截断内容都自动换下一个，全部失败时报"已尝试 N 个源"
- CLI 四个子命令；三个集成示例（含服务端复用模式）
- 107 项测试，单元测试与模型集成测试分层

### Flutter 端（M1、M2、M3、M5 完成，M4 基础、批量流程、双语导出、第三方 API provider、文件/实时字幕/视频字幕翻译工作流已完成，M6 设置页与模型管理首期已完成：`flutter analyze` 无告警，相关测试通过）

- 三端工程骨架（windows / macos / android）
- 129 个锁定依赖，含 `sherpa_onnx 1.13.5` 全部平台原生库子包、`media_kit` 视频播放栈和设置持久化插件
- Gradle 国内镜像（阿里云 Maven + 腾讯云 Gradle 发行版）
- 六个引擎文件移植完成，Python 端修过的 bug 一并带过来：
  - 空格 token 不能丢（否则英文字幕拼成 `with50`）
  - 无 token 时间戳的长段要遵守时长上限
  - 下载要比对 `Content-Length`，截断文件不能当有效缓存
  - 坏压缩包解压失败后必须删除，否则永远复用
- **音频解码层**（M1 第一项）：
  - `wav.dart` 纯 Dart 读 WAV —— 8/16/24/32 位整型 + 32/64 位浮点、任意声道混单声道、
    跳过 LIST/fact 等 chunk、`data` size 写 0 或超长都能容错、非 16 kHz 走线性重采样
  - `audio_decoder.dart` 统一入口：wav 走纯 Dart，压缩格式与视频容器转给平台原生通道
    `vsasr/audio_decoder`；扩展名是 wav 但内容是 ADPCM 之类时自动退回原生
  - macOS 原生实现（`MainFlutterWindow.swift`）：`AVAssetReader` + `AVAssetReaderAudioMixOutput`，
    混声道与重采样都交给 AVFoundation，在后台队列解码
  - Android 原生实现（`MainActivity.kt`）：`MediaExtractor` 选第一条音轨 + `MediaCodec` 同步收发循环；
    MediaCodec 只吐原始 PCM，**混声道与重采样都得自己做**，重采样用与 `wav.dart` 逐行等价的线性插值
  - Windows 原生实现（`windows/runner/audio_decoder.cpp`）：Media Foundation `IMFSourceReader`，
    先要 16 kHz/单声道/float32（让系统自动插 Audio Resampler MFT），被拒则逐档降级
    （float 原样 → 16 位 16 kHz 单声道 → 16 位原样）后自己混声道 + 重采样
  - 三端都是「解码在后台、回包在主线程」：macOS 用 `DispatchQueue.main`，Android 用
    主线程 `Handler`，Windows 用一个 message-only 窗口把结果从工作线程搬回平台线程
  - 33 项 Dart 单测覆盖上述分支，其中一项直接读模型自带的 `yue.wav`：解出 82368 个采样，
    与 Python 端 `audio.load()` 的结果一致（16 kHz 素材不经插值，逐字对照的前提成立）
- **后台识别 isolate**（M1 第二项，`transcription_worker.dart`）：常驻 isolate，
  模型只加载一次，请求串行（同一个识别器不能并发用），进度与模型下载进度都经
  端口回报到主 isolate；启动失败不留野 isolate，`dispose()` 先让 isolate 自己
  释放原生资源、超时才硬杀。抽了个 `Transcriber` 接口，测试用替身工厂就能跑通
  整条 isolate 链路而不加载原生库（8 项）
- **界面层**（M1 后两项，`lib/src/ui/`）：
  - `transcribe_controller.dart` 是唯一的状态机（模型准备 → 解码 → 识别 → 导出），
    界面只读它的字段；解码器、模型目录、转写器启动方式三处依赖都可注入，
    所以整条链路能在 `flutter test` 里跑通
  - `home_page.dart`：模型未就绪时是下载页（进度、失败重试、三源 fallback 说明），
    就绪后是工具条 + 进度条 + 分段列表（序号/时间戳/语言）+ 底部统计（段数、时长、耗时、RTF）
  - 导出走 `file_picker` 12 的 `saveFile`（它自己落盘，顺带处理 Android SAF 与 macOS 沙盒授权），
    格式对话框列 SRT/VTT/JSON/TXT，文件名默认跟着音频名
  - 14 项测试：7 项状态机 + 7 项 widget（含「没有结果时导出按钮禁用」「解码失败展示原文案」）
- **端到端验收**（`integration_test/e2e_test.dart`，7 项，在 macOS 上跑真模型真引擎）：
  `flutter test integration_test/e2e_test.dart -d macos`。结果与 Python 端**逐字一致**：
  `呢几个字都表达唔到，我想讲嘅意思。`，RTF ≈ 0.06；`yue.m4a` 走 macOS 原生解码后
  识别结果同样一致 —— Swift 那份解码器至此才算真跑通
- **修掉两个会在打包后才暴雷的配置问题**：
  - macOS `entitlements` 缺 `network.client`（sandbox 会静默掐掉模型下载）、
    缺 `files.user-selected.read-only`（file_picker 选中的文件读不了）
  - Android `main/AndroidManifest.xml` 缺 `INTERNET`（模板只在 debug/profile 里声明，
    release 包装机后拿不到模型）
- **实时字幕**（M2，2026-08-15）：
  - `streaming_transcriber.dart` 对应 Python 端 `streaming.py`：VAD 定稿 + 定期整句重解码出局部结果。
    Dart 绑定没有 `currentSegment`，因此自维护当前句缓冲区，并保留 0.5 秒回看窗口补上句首
    （VAD 要连续听到 `minSpeechDuration` 才认定在说话，此前的窗口已经喂进去了）
  - VAD 与解码器都抽成接口（`SpeechSegmenter` / `SegmentDecoder`），
    所以整条流式逻辑能在没有原生库的环境里单测（12 项）
  - 识别 isolate 多了一条实时通道：`startLive()` → 音频块进、`Segment` 出，
    同一时刻只允许一路会话，`dispose()` 会把开着的会话收掉（3 项）
  - `microphone.dart` 用 `record` 7.1.1 取 16 kHz 单声道 PCM16 流并转 float32；
    权限用它自带的 `hasPermission()`（会发起运行时申请），**不需要 `permission_handler`**
    （该依赖已从 `pubspec.yaml` 移除）；每场录音换一个 `AudioRecorder`（5 项）
  - `live_controller.dart` 是实时字幕的状态机，与文件转写**共用同一个 worker**
    （模型 240 MB，加载两份手机上直接爆），通过 `TranscribeController.ensureWorker()` 借用（16 项）
  - `home_page.dart` 拆成「文件转写 / 实时字幕」两个页签；临时结果在列表最后一行斜体带省略号、
    原地刷新，定稿后变成带序号与时间戳的正式条目（8 项 widget 测试）
  - macOS `Info.plist` 补 `NSMicrophoneUsageDescription`（缺了它是**直接闪退**而不是弹授权框）
  - 顺带修掉一个内存隐患：切语言时旧 isolate 还在关，新的就抢先加载了，
    两份模型同时驻留；`prepare()` 现在先等旧的关完

- **视频播放与字幕联动（M3，2026-08-16）**：
  - 采用 `media_kit` + `media_kit_video` + `media_kit_libs_video`，统一覆盖 Android、macOS、Windows；
    macOS 插件当前不支持 Swift Package Manager，已由 CocoaPods 集成并完成 macOS 编译验证
  - 新增视频播放页：打开视频、播放/暂停、拖动进度、显示当前识别字幕；视频转写复用 M1 的原生抽音轨路径
  - 字幕列表跟随播放位置高亮，点击任一字幕跳转到对应时间；播放器后端可注入替身，便于无原生库单测
  - 代码审查补上异步收尾生命周期保护，以及无扩展名路径的安全判断；新增 4 项播放器/视频页测试
  - 生成模型自带英文语音的 `en.mp4`，在 macOS 上通过真实 `media_kit` 播放、跳转、视频抽音轨、识别与字幕时间轴校验

- **翻译基础抽象（M4 第一项，2026-08-16）**：
  - 新增服务商无关的 `TranslationProvider` 契约，HTTP 协议、认证和重试策略留给具体 provider
  - 新增 `translateResult()`：只发送非空字幕段，校验返回数量后按原位置写入 `Segment.translation`，不改变时间轴
  - 新增 4 项单测覆盖自动语言、空段保留、返回数量不一致和空目标语言
  - 具体在线翻译服务商采用可配置的 OpenAI-compatible 第三方 API，接口层仍不绑定具体品牌或计费方案

- **双语字幕导出（M4，2026-08-16）**：
  - `subtitles.dart` 已接通 `Segment.translation`，SRT/VTT/TXT 输出原文与译文双行，JSON 保留结构化译文
  - 带译文的长段保持单条 Cue，避免原文和译文切分后时间边界错位；新增 4 项导出回归测试

- **第三方 API 在线 provider（M4，2026-08-17）**：
  - 使用可配置的 Chat Completions endpoint、模型和 `Authorization: Bearer ...`，要求返回等长 JSON 字符串数组
  - provider 支持自定义 HTTP client、超时、错误脱敏和响应数量校验，API Key 仅通过构造参数注入；单次实时录音会话复用 provider，收尾时统一释放
  - 新增 3 项无网络单测覆盖请求格式、响应格式、HTTP 错误和构造参数
  - 保留旧 `DeepLTranslationProvider` 及其兼容测试，现有应用工作流不再默认使用 DeepL

- **API Key 安全存储基础（M6 第一项，2026-08-16）**：
  - 接入 [`flutter_secure_storage`](https://pub.dev/documentation/flutter_secure_storage/latest/)，通过平台安全存储保存第三方翻译 API Key，不写入代码或普通配置
  - 固定 provider-specific 存储键，写入前去空白、拒绝空值，支持读取和删除；新增 3 项无网络测试
  - macOS Debug/Release entitlements 已加入 Keychain Sharing；设置页可保存 API Key 和识别配置，启动时恢复配置，新增 5 项设置页/持久化测试

- **模型管理与离线模式（M6 第二项，2026-08-16）**：
  - 设置页显示模型就绪状态与磁盘占用，支持显式下载、确认后删除本地模型；删除前等待旧 worker 完全释放，避免模型文件仍被占用
  - 离线模式持久化到 `shared_preferences`，自动准备模型时禁止联网；设置页的显式下载仍可用
  - 模型占用统计在后台刷新，不阻塞首页从下载页切换到识别界面；统计失败不影响已就绪模型
  - 新增 4 项离线/模型生命周期测试，覆盖自动下载策略、占用空间、删除清理和配置变更并发边界

- **字幕校对编辑（M5，2026-08-16）**：
  - 新增独立的 `SubtitleEditorController`，以不可变结果快照实现撤销/重做，编辑失败时不污染当前结果
  - 支持文本、起止时间、合并、拆分；文本变化清除过期译文和 token 时间戳，时间变化清除过期 token 时间戳
  - 首页和视频页接入字幕校对入口，编辑页可定位播放器时间点，保存后回写主转写结果
  - 导出前统一校验时间轴，拒绝负时间、无效区间、重叠/倒序和超出音频时长的字幕
  - 新增 9 项编辑器/页面/导出回归测试，全量 `flutter test` 共 166 项通过

- **应用内翻译工作流（M4，2026-08-16）**：
  - 主转写页和视频播放页新增翻译入口，从系统安全存储读取第三方翻译 API Key，设置页可配置 endpoint/模型，provider 可注入测试替身
  - 实时字幕页新增“实时翻译”开关，定稿字幕进入串行翻译队列，译文异步显示在原文下方；停止/销毁时使未开始的排队请求失效，避免网络异常逐条阻塞收尾
  - 翻译期间锁定转写状态并显示批量进度；所有批次成功后才一次性写回译文，失败时保留原识别结果
  - 转写列表显示译文，后续 SRT/VTT/TXT/JSON 导出和视频字幕叠加复用同一份结果
  - 新增 4 项状态机/界面回归测试；全量 `flutter test` 已增至 166 项

### 环境

两台机器，代码同一份：

**macOS（当前仓库所在的机器）**

```
~/development/flutter    Flutter 3.47.0 stable / Dart 3.13.0（腾讯云镜像下载，见 §6）
系统 ffmpeg 7.x          Python 端解码用
Xcode 26.6               2026-08-15 装好
CocoaPods 1.17.0         brew 装（Flutter 3.47 默认走 SPM，但 doctor 仍要求它）
flutter build macos       ✅ 通过，Swift 原生解码已编译
Android SDK               /opt/homebrew/share/android-commandlinetools，platform 36，build-tools 36.1.0，NDK 28.2.13676358，JDK 17
flutter build apk/appbundle ✅ 通过；APK/AAB 仅作构建验证，release 使用 debug signing
Android Emulator          API 35 arm64 `vsasr-api35`；真实端到端 7 项通过，软件渲染，仅作功能验证
```

**Windows（此前的开发机，全部在 E 盘）**

```
E:\dev\flutter        Flutter 3.47.0 stable / Dart 3.13.0
E:\dev\android-sdk    platforms 36 + 37.0、build-tools 36.1.0、platform-tools
```

**Windows CI（已验证）**

```
GitHub Actions windows-2022    Flutter 3.47.0 + MSVC + Inno Setup 6
Run 31914757787                Release、桌面 smoke、产物校验与 artifact 上传均通过
Run 31919855391                完整模型 e2e 7 项、桌面 smoke、产物校验与 artifact 上传均通过
```

## 4. 阶段计划

每个阶段都以「能跑起来给人看」为验收标准，不做只有代码没有验证的阶段。

### M0 · 解除构建阻塞（前置，需要人工介入）

阻塞项取决于在哪台机器上构建，两条路径互不依赖，先打通任意一条即可开始 M1。

**macOS 路径（本仓库当前所在的机器，推荐先走这条）**

| 事项 | 说明 | 状态 |
| --- | --- | --- |
| 装 Flutter SDK | 3.47.0 已装在 `~/development/flutter`（brew 走 googleapis 太慢，改用腾讯云镜像，见 §6） | ✅ 完成 |
| 验证引擎层 | `flutter pub get` → `flutter analyze` **No issues found** → `flutter test` **166 项通过** | ✅ 完成 |
| Xcode + CocoaPods | Xcode 26.6 已装（用户）；CocoaPods 1.17.0 由 `brew install cocoapods` 装。无签名模式的 `xcodebuild` 已成功编译并打包（含 secure storage plugin）；个人使用的无签名包已满足目标，普通 `flutter build macos --debug` 的开发证书仅在需要正式签名运行/发布时才需要。另有 pub 会抹掉 `SherpaOnnxC.framework` 符号链接的问题，见 §6 | ✅ 个人使用构建完成 |

macOS 路径不需要开发者模式，也不需要 Visual Studio —— 而且 macOS 安装包只能在 Mac 上产出（见 §6），
所以这条路径顺带解决了 M7 里原本无解的一项。

**Windows 路径**

| 事项 | 说明 | 谁做 |
| --- | --- | --- |
| 开启 Windows 开发者模式 | Flutter 构建带插件项目需要符号链接权限。`start ms-settings:developers` | 用户（需权限） |
| Visual Studio C++ 工具链 | Windows 桌面构建必需，约 5–7 GB，安装会弹 UAC | 用户授权后由 AI 执行 |

**Android（两条路径都可用）**

| 事项 | 说明 | 谁做 |
| --- | --- | --- |
| 真机或模拟器 | 本机已安装 API 35 ARM64 `vsasr-api35` 模拟器并通过功能端到端测试；真机仍未连接，性能需实机测量 | 用户插机器 / AI 装模拟器 |

**M0 不完成，M1 之后的所有阶段都无法验证。**

### M1 · 最小闭环：文件转写 + 字幕导出　✅ 已完成（2026-08-15）

目标：选一个音频文件 → 识别 → 看到分段与时间戳 → 导出 SRT。

- [x] 音频解码层（方案见 §5 已决策 1）：Dart 侧 `AudioDecoder` 接口 + wav 纯 Dart 直读；
      压缩格式/视频转 `vsasr/audio_decoder` 原生通道
  - [x] macOS 原生实现（AVAssetReader，**已编译且已在真机跑通**：
        端到端测试里解 `yue.m4a` 得到与 wav 一致的识别结果）
  - [x] Android 原生实现（MediaExtractor + MediaCodec + 自己混声道与重采样，
        **已在 Android 15 API 35 ARM64 模拟器端到端运行验证；真机性能仍未验证**）
  - [x] Windows 原生实现（Media Foundation IMFSourceReader，
        **已在 GitHub Actions windows-2022 runner 编译，并通过桌面 smoke 与完整模型 e2e 验证 AAC 解码；用户桌面运行仍未验证**）
- [x] `AsrEngine` 放入 isolate，避免长音频卡 UI；`initBindings()` 需在每个 isolate 内单独调用
      （`transcription_worker.dart`：常驻 isolate、模型只加载一次、请求串行；
      8 项测试用替身工厂跑通整条链路，不加载原生库）
- [x] 文件选择（`file_picker`）、进度条、分段列表、导出对话框
      （`lib/src/ui/`：`transcribe_controller.dart` 状态机 + `home_page.dart` 界面，
      7 项状态机测试 + 7 项 widget 测试）
- [x] 模型首次下载页：进度、失败重试、多源 fallback 提示
- [x] **验收通过**：同一个 `test_wavs/yue.wav` 在 Flutter 端与 Python 端输出**逐字一致** ——
      两端都是 `呢几个字都表达唔到，我想讲嘅意思。`，解码同为 82368 个采样。
      验收自动化在 `integration_test/e2e_test.dart`（真模型、真引擎、真原生解码，7 项）

### M2 · 麦克风实时字幕　✅ 已完成（2026-08-15）

- [x] `record` 包取 PCM stream → `VadSession`（`microphone.dart`：16 kHz 单声道 PCM16 → float32）
- [x] 自维护 partial 缓冲区（Dart 绑定没有 `currentSegment`，见 §6）；
      额外补了 0.5 秒句首回看，否则局部结果缺开头几个字
- [x] 临时结果原地刷新、定稿追加的列表 UI（`home_page.dart` 的实时字幕页签）
- [x] Android 麦克风运行时授权 —— 用 `record` 自带的 `hasPermission()` 发起申请，
      **没有引入 `permission_handler`**（`RECORD_AUDIO` 已在 manifest 里声明）
- [x] macOS `Info.plist` 补 `NSMicrophoneUsageDescription`（缺了它一请求麦克风就崩；
      `device.audio-input` entitlement 已加）
- [x] **验收通过（macOS）**：端到端测试把 zh/en/yue 三段素材拼成「三句话」，
      按 100 ms 一块喂进实时会话 —— 四句全部定稿（英文那段被 VAD 切成两句）、
      `index` 从 0 连续递增、时间戳不重叠不倒序，过程中有局部结果上屏。
      麦克风那一路本身没法自动化（要真人说话），但它之后的链路与该测试完全相同
- [x] **Android 模拟器功能闭环** —— API 35 ARM64 模拟器通过 7 项端到端测试：模型目录、WAV、Kotlin 原生 m4a 解码、识别、视频播放/跳转/抽音轨、实时识别；2026-08-16 重跑 7/7，通过粤语识别 RTF `0.027`
- [ ] **Android 真机不掉帧 —— 未验证**（模拟器使用软件渲染，不能替代中低端真机性能测试）
- [x] **Windows CI 桌面 smoke** —— run `31914757787` 在 Windows runner 上通过真实 AAC 原生解码、media_kit MP4 打开/读取时长/播放；未加载 ASR 模型
- [x] **Windows 完整模型 e2e** —— run `31919855391` 在 Windows runner 上通过 7 项测试：模型目录、WAV、m4a 解码、粤语 wav/m4a 识别、真实 mp4 播放/跳转/抽音轨识别、实时三句识别；粤语 wav RTF `0.064`。workflow 使用三源 fallback、有限重试、最低 256 KiB/s 低速超时、大小校验、Actions cache、7-Zip 分层解压和 `VSASR_MODEL_DIR` 外部模型目录

### M3 · 视频播放 + 字幕叠加　✅ 已完成（2026-08-16）

- [x] 播放器：采用 `media_kit`，已接入 Android/macOS/Windows 依赖与统一控制器
- [x] 从视频抽音轨 → 识别 → 字幕轨：复用 M1 的平台原生解码并在视频页加载识别结果
- [x] 播放进度与字幕高亮联动，点字幕跳转
- [x] 验收：模型自带英文语音生成的 `en.mp4` 在 macOS 上通过真实 `media_kit` 播放、跳转、视频抽音轨、识别与字幕时间轴校验；Android API 35 模拟器同样通过真实播放器、跳转、抽音轨与识别测试

### M4 · 翻译（识别语言 → 中文；基础、批量、双语导出、第三方 API provider、文件/实时字幕/视频字幕工作流已完成）

- [x] `TranslationProvider` 抽象：`Future<List<String>> translate(List<String> texts, {String? from, required String to})`；`translateResult()` 已将等长译文安全写入 `Segment.translation`
- [x] 在线 provider 实现：`ApiTranslationProvider` 支持可配置的 OpenAI-compatible Chat Completions endpoint、模型和 Bearer API Key
- [x] 批量翻译 + 失败重试 + 进度回报；支持 `batchSize`、`maxRetries`、`retryDelay`，所有批次成功后写入 `Segment.translation`
- [x] 双语字幕导出：SRT/VTT/TXT 输出原文+译文双行，JSON 保留 `Segment.translation`；已有导出链路并通过 4 项回归测试
- [x] 应用内翻译工作流：从安全存储读取第三方翻译 API Key，在文件转写页发起翻译、显示进度并回写结果；失败不写入半成品
- [x] 实时字幕翻译：实时页支持开关；每条定稿字幕异步调用第三方 API，译文显示在原文下方，并按顺序写回
- [x] 视频播放字幕翻译：视频页可复用同一第三方 API 翻译已转写结果，视频叠加字幕和字幕列表同步显示译文
- [ ] 验收：英/日视频生成双语字幕，真实 API 网络验收需使用用户自己的第三方服务商密钥，按个人使用范围暂不作为交付门禁

### M5 · 字幕校对编辑　✅ 首期已完成（2026-08-16）

- [x] 可编辑列表：改文字、调起止时间、合并/拆分字幕条
- [x] 撤销/重做
- [x] 与播放器联动（编辑时定位到对应时间点）
- [x] 验收：改完导出的 SRT 时间轴无重叠、无倒序；导出入口统一复用时间轴校验

### M6 · 设置页与模型管理

- [x] 语言、线程数、VAD 断句灵敏度、临时结果间隔；设置保存到 `shared_preferences`
- [x] 模型下载/删除/占用空间、离线模式开关
- [x] API Key 安全存储基础：`flutter_secure_storage` 适配器、固定存储键、非空校验、读取/删除和 macOS Keychain entitlements；无签名环境不可用时退回当前会话存储
- [x] 设置页接入第三方翻译 API 配置（endpoint、模型和 API key 不落普通明文配置）
- [x] 验收：保存后立即应用并重启启动时恢复；控制器重启和持久化分别有测试覆盖

### M7 · 打包分发

- [x] Android APK / AAB（本机已构建：APK 约 169 MiB、AAB 约 124 MiB；APK 通过 v2 签名校验，未提供签名变量时使用 debug signing，仅完成构建验证）
- [x] Android 可选外部签名配置（`app/android/app/build.gradle.kts` 支持显式 `VSASR_ANDROID_KEYSTORE_FILE`、`VSASR_ANDROID_KEY_ALIAS`、`VSASR_ANDROID_KEYSTORE_PASSWORD`、`VSASR_ANDROID_KEY_PASSWORD`；缺少任一变量会在配置时失败，不会静默生成 debug 签名发布包；已用临时 keystore 构建并通过 `apksigner` v2 校验）
- [x] Android 个人使用产物验收 —— JDK 17 与构建链路已验证；未提供外部签名变量时生成的 debug-signed APK 可个人安装和测试，正式发布证书不在范围
- [x] Windows exe + 安装包（GitHub Actions run `31912544699` 已通过；自动检查 `vsasr_app.exe`、安装包和四个运行时 DLL，Release 目录约 111 MiB，`VoiceSmallASR-unsigned-setup.exe` 约 31 MiB，未签名）
- [x] **macOS 无签名 `.app`/`.dmg` 可复现构建** —— `scripts/build_macos_unsigned.sh` 使用 Xcode Release 构建并生成通用 arm64/x86_64 `.app` 与 UDZO `.dmg`；个人使用不要求开发者证书，App Store/公证发布另行配置
- [x] 模型不打进安装包（约 240 MB 模型仍由首次运行下载）；已检查 macOS `.app`、Android APK/AAB，Windows CI 也自动拒绝 `.onnx`、`.tar`、`.bz2` 和 `tokens.txt`
- [x] 三端 GitHub Release —— `.github/workflows/release.yml` 已在云端完成 `v1.0.1` 发布，包含 Android APK/AAB、Windows 未签名安装包和 macOS 未签名 DMG/APP 压缩包：[GitHub Release](https://github.com/2653533859/VoiceSmallASR/releases/tag/v1.0.1)

### M8 · 发布质量基线（v1.0.2，代码已落地）

- [x] Python/Flutter 质量门禁：pytest、Ruff、Flutter analyze、Flutter 全量测试；失败时阻止 Release job
- [x] Release Tag 注入 Android、macOS、Windows 应用版本，并检查 Tag 与 `app/pubspec.yaml` 一致
- [x] 三端最终产物排除模型文件：Android APK/AAB、macOS App/ZIP/DMG、Windows Release 目录
- [x] Release job 生成 `SHA256SUMS.txt` 和 `BUILD_INFO.txt`，上传到 GitHub Release
- [x] 模型完整性校验失败时清理旧压缩包，允许下一次从下载源重新获取
- [ ] 推送 `v1.0.2` Tag，完成一次云端全流程 Release 验收

### M9 · 无签名环境的翻译体验（已完成）

- [x] 设置页增加目标语言选择并持久化；默认目标语言为中文
- [x] 文件、视频和实时字幕翻译使用统一的目标语言设置
- [x] 设置页增加 API 连接测试，显示 endpoint、模型和脱敏错误，不显示 API Key
- [x] 设置页明确显示 API Key 使用系统安全存储还是当前会话存储
- [x] 实时翻译失败后支持单条字幕重新翻译；关闭实时翻译时不隐式发送请求
- [x] 翻译前提示字幕文本会发送给用户配置的第三方服务商，覆盖文件、视频和实时字幕入口

### M10 · 真实设备与下载安全验收（环境审计）

- [x] Windows 最新提交已由 CI run `32008744063` 通过 Flutter analyze、Release 构建、桌面 smoke、产物校验和 artifact 上传；完整模型 E2E 由 run `31919855391` 通过
- [ ] Android 真机性能、内存和 RTF：本机 `flutter devices` 仅发现 macOS 与 Chrome，没有连接真机或无线设备
- [ ] Windows 用户桌面干净目录安装、首次启动和真实设备差异：当前只有 Windows runner 结果，尚未有可操作的用户桌面

### M11 · 项目保存与字幕导入（已完成）

- [x] 定义版本化项目 JSON schema，保存媒体路径引用、识别配置、字幕分段、译文和 token 时间戳
- [x] 项目文件读写使用同目录临时文件，并在读写前后校验 schema、版本和字幕时间轴
- [x] 控制器支持生成项目快照和恢复项目配置/当前结果
- [x] 首页接入保存项目和打开项目；保存媒体引用、识别配置、字幕时间轴与译文，并覆盖按钮禁用、恢复和保存提示
- [x] 最近项目列表：保存/打开成功后置顶，最多持久化 8 个路径
- [x] Android SAF URI / provider path：项目可直接从 `PlatformFile` 字节读取，并在应用支持目录缓存稳定副本
- [x] 自动保存与异常恢复：识别、字幕编辑、配置变更和翻译成功后防抖写入应用支持目录；会话锁用于区分正常退出与异常退出，启动时可恢复或放弃快照
- [x] 原媒体文件不存在时的可恢复提示：允许继续使用字幕或重新选择媒体，重新定位只更新项目引用并纳入自动保存
- [x] SRT/VTT/JSON 字幕导入：支持 SRT/VTT 时间轴解析、基础标签清理、项目结果 JSON 导入和时间轴校验；Android SAF 无本地路径时按字节读取
- [x] 视频页加载外部字幕：绑定当前视频后复用字幕叠加、编辑、第三方 API 翻译和导出链路

### M12 · 批量处理工作流（多文件队列首项完成）

- [x] 多文件选择与去重、顺序转写、每文件状态/进度展示
- [x] 暂停/继续、取消、失败重试；取消不会让迟到结果写回，也不会继续处理后续文件
- [ ] 批量翻译复用 provider、按原文件名安全导出、已完成文本缓存和队列恢复

## 5. 决策记录与待决策事项

### 已决策 1 · 音频解码 = 三端各写原生解码（2026-08-15 定）

Python 端靠 ffmpeg 解 mp3/m4a/视频。Dart 侧没有这个便利：`sherpa_onnx` 自带的 `readWave()` 只认 wav，而 M3 的视频字幕必须能从 mp4 抽音轨。

**结论：三端各写一份原生解码，走 platform channel。** 体积零增长、性能最好、不依赖任何第三方
ffmpeg 封装包，代价是工作量约 3 倍。

| 平台 | 原生 API | 落地文件与状态 |
| --- | --- | --- |
| Android | `MediaExtractor` + `MediaCodec` | `android/.../MainActivity.kt` —— 已随 release APK/AAB 编译并在 API 35 模拟器运行验证，尚未真机运行；解出 PCM 后自己混声道 + 重采样 |
| macOS | `AVAssetReader` + `AVAssetReaderAudioMixOutput`（AVFoundation） | `macos/Runner/MainFlutterWindow.swift` —— 已无签名编译验证；混声道与重采样都由 AVFoundation 给 |
| Windows | Media Foundation `IMFSourceReader`（`MFCreateSourceReaderFromURL`） | `windows/runner/audio_decoder.cpp` —— 已在 Windows CI 编译，并通过 AAC 桌面 smoke 与完整模型 e2e（run `31919855391`）；先要 `MF_MT_AUDIO_*` = 16 kHz/单声道/float32，被拒则自己算 |

Dart 侧的契约统一为一个方法：给文件路径，返回 16 kHz float32 单声道 `Float32List`
（与 `AsrEngine.transcribe` 的入参一致），三端各自实现，Dart 层不感知平台差异。

**已作废的方案 `ffmpeg_kit_flutter`（2026-08-15 核实）**：pub.dev 上标记为 **discontinued**，
最新版 6.0.3 已约两年未更新，上游 `arthenica/ffmpeg-kit` 仓库于 **2026-07-02 归档**；
且它**从未支持 Windows**（只有 Android / iOS / macOS），与三端目标直接冲突。体积从来不是它的主要问题。
社区 fork（如 `ffmpeg-kit-extended`）虽声称覆盖 Windows，但同属个人维护，弃养风险与原包同构，故不采用。

### 已决策 2 · 在线翻译服务商（第三方 OpenAI-compatible API，2026-08-17）

已定方向：保留可插拔 `TranslationProvider` 接口，当前使用可配置的 OpenAI-compatible Chat Completions API，默认 endpoint 为
`https://api.openai.com/v1/chat/completions`，默认模型为 `gpt-4o-mini`；第三方服务商只要兼容该请求/响应格式即可，也可在设置页替换 endpoint 和模型。若实际服务商协议不兼容，再新增对应 provider 适配器，不改翻译工作流。
API Key 的安全存储基础已接入 [`flutter_secure_storage`](https://pub.dev/documentation/flutter_secure_storage/latest/)，设置页配置已接入 M6；普通设置使用 [`shared_preferences`](https://pub.dev/packages/shared_preferences) 持久化。真实 API Key 和真实网络验收不写入自动化测试。

### 已决策 3 · 字幕编辑状态与项目文件格式（M5，2026-08-16）

首期采用独立的 `SubtitleEditorController` 和不可变 `TranscriptionResult` 快照栈实现撤销/重做，不新增 `riverpod` 或工程文件格式。工程文件、批量编辑和更细的编辑命令可在后续需求明确后再扩展。

## 6. 已知技术约束与踩坑记录

这一节是给未来的自己看的 —— 都是实测踩过的，不要重踩。

### Python 端

- **`sherpa-onnx` 与 `sherpa-onnx-core` 必须同版本且都要显式声明。** PyPI 索引元数据没有声明 core 依赖，uv 不会自动装。缺了它扩展模块会退回加载 `C:\Windows\System32\onnxruntime.dll`（1.17.1），报 `requested API version [27] is not available` 后**直接段错误**。
- **`requires-python` 下限是 3.11.4 而非 3.11.0。** `tarfile` 的 `filter="data"`（PEP 706）在 3.11 系列直到 3.11.4 才回补。
- **VAD 的 `front` 返回内部对象引用**，必须在 `pop()` 之前把 samples 拷出来，否则拿到空数组。
- **不能整段一次性喂 VAD**，要按 `window_size`(512) 分批，否则段起点判定失准（实测整段喂时 5.15s 音频的段起点被判成 4.806s）。
- **靠 `Content-Length` 判截断，在镜像源上会整个失效**（2026-08-15 代码审查发现）：
  `ghfast.top` / `gh-proxy.com` 是流式代理，常用 chunked 编码不给长度，于是
  `if total and done != total` 恒不成立，半截文件照样被 `replace()` 成正式缓存。
  压缩包还有解压失败兜底（坏包会被删），**`silero_vad.onnx` 没有**，一旦装成缓存
  就每次运行都加载失败，除了手工删没有出路。因此 `ModelSpec` 加了 `min_bytes` 保守下限，
  没有总长度时用它兜底。Dart 端 `model_manager.dart` 有同样的逻辑，两端必须一起改。
- **`http.client.IncompleteRead` 不是 `OSError` 的子类**（它继承 `HTTPException`），
  而 chunked 响应中途断连抛的正是它。多源 fallback 只 `except OSError` 时，
  第一个镜像断连会让异常直接穿出去，**后面两个源根本不会被尝试**。

### Flutter 端

- **Dart 绑定没有 `currentSegment`** —— 流式局部结果要自己维护缓冲区，起点会比 VAD 判定略晚。
- **Dart 绑定没有 `decodeStreams`** —— 只能逐段解码，靠 isolate 并行补性能。
- **Dart 绑定没有 `durations`** —— token 结束时间取下一个 token 的起点（SenseVoice 的 `durations` 实测本来就是空的，与 Python 端行为无差别）。
- **好消息：Dart 的 `vad.front()` 内部已拷贝 samples**，不存在 Python 端那个失效坑。
- **`initBindings()` 每个 isolate 都要单独调用**，否则抛 "Please initialize sherpa-onnx first"。
- **平台通道只在 root isolate 上可用**（后台 isolate 要用得先
  `BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken)`）。因此分工是：
  音频解码留在主 isolate（原生侧本来就在后台线程解），只把 `Float32List` 送进识别 isolate。
  **但识别 isolate 自己也要用平台通道** —— `ModelManager` 靠 path_provider 找模型目录，
  不接上就抛 "BackgroundIsolateBinaryMessenger.instance value is invalid"。
  这个坑是端到端测试里才暴出来的：单测用替身工厂，根本走不到 path_provider。
- **接了 background messenger 之后，isolate 不会因为关掉自己的端口而退出** ——
  那个常驻端口一直挂着。表现是 `dispose()` 每次都等满 gracePeriod（5 秒）再硬杀，
  测试套件从 1 秒变 30 秒。收尾必须显式 `Isolate.exit()`，且**要先 free 原生资源**：
  原生内存属于进程，isolate 退出不会替你释放。
- **跨 isolate 只能传顶层/静态函数**，捕获了状态的闭包传不过去。
  `TranscriptionWorker` 的工厂参数因此定成 `TranscriberFactory` 顶层函数类型 ——
  也正好让测试能塞替身工厂，在没有原生库的环境里跑通整条链路。
- **命名参数不允许以下划线开头**：`prefer_initializing_formals` 这条 lint 碰到私有字段时
  会给出无法采纳的建议（`this._x` 当命名参数是语法错误），改成位置参数即可消掉。
- **240 MB 模型解压必须放 isolate 流式落盘**，一次性读进内存在手机上会 OOM。
- **macOS sandbox 会静默掐掉出网**：`entitlements` 不加 `com.apple.security.network.client`，
  模型下载不会报权限错误，只会像网络故障一样失败。`files.user-selected.read-only` 同理，
  不加则 file_picker 选中的文件读不出来。两个 entitlements 文件（Debug/Release）都要改。
- **`flutter_secure_storage` 的 macOS Keychain Sharing 需要签名能力**：Debug/Release 两个
  entitlements 都要加 `keychain-access-groups`；没有开发证书时可用
  `xcodebuild ... CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` 验证编译并生成个人使用的无签名包。
  当前应用检测到安全存储不可用时会退回仅当前会话的 API Key，不写入普通配置；需要跨重启持久化时仍需签名运行环境。
- **Android 的 `INTERNET` 权限在 release 包里会消失**：Flutter 模板只在
  `debug/` 与 `profile/` 的 manifest 里声明它（那是给 hot reload 用的），
  `main/AndroidManifest.xml` 不写就等于 release 包没有网络权限。
- **pub 会抹掉符号链接，导致 macOS 构建在 codesign 一步失败**（2026-08-15 实测）：
  `sherpa_onnx_macos` 里的 `SherpaOnnxC.framework` 是 macOS 的**版本化 framework**，
  正常由 `Versions/Current` 等符号链接组织；而 pub 包不支持符号链接，解压后它们变成三份
  真实副本（163 MB），bundle 结构不合法，Xcode 报
  `code object is not signed at all` + `Couldn't resolve framework symlink for .../Versions/Current`，
  `flutter build macos` 直接失败。修法是在 pub cache 里把符号链接补回去：

  ```bash
  F=~/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.5/macos/sherpa_onnx_macos/SherpaOnnxC.xcframework/macos-arm64_x86_64/SherpaOnnxC.framework
  cd "$F" && rm -rf Versions/Current Headers Modules Resources SherpaOnnxC
  ln -s A Versions/Current
  for n in Headers Modules Resources SherpaOnnxC; do ln -s "Versions/Current/$n" "$n"; done
  ```

  三份副本内容完全相同（sha1 一致），删掉重建符号链接后体积从 163 MB 降到 54 MB。
  改的是**共享的 pub cache**，`flutter pub cache repair`、升级该包或换机器后都要重做。
  Flutter 3.47 默认走 Swift Package Manager，`macos/Flutter/ephemeral/Packages/.packages/`
  下是指向 pub cache 的符号链接，所以修缓存就够了，不必动工程。
- **Flutter 3.47 的 macOS 产物是「壳 + debug dylib」**：`Contents/MacOS/vsasr_app` 只有 59 KB，
  Swift 代码在同目录的 `vsasr_app.debug.dylib` 里。想确认某段原生代码有没有真的编译进去，
  要对那个 dylib 做 `nm`/`strings`，对主二进制搜是搜不到的。
- **给 macOS Runner 加 Swift 文件要同时改 `project.pbxproj`**，手改容易把工程文件弄坏；
  因此原生解码器暂时写在已在编译列表里的 `MainFlutterWindow.swift` 内。现在 Xcode 有了，可以拆。
- **原生解码的回包必须回到主线程 / 平台线程**：解码本身在后台（否则界面卡死），
  但 Android 要用主线程 `Handler` post，Windows 的 `flutter::MethodResult` 只能在平台线程上用 ——
  runner 里拿不到 engine 的 task runner，所以自建了一个 `HWND_MESSAGE` 窗口，
  工作线程 `PostMessageW`、窗口过程里回包。
- **`MediaFormat.containsKey` 与 `getInteger(key, default)` 是 API 29 才有的**，minSdk 比它低，
  直接调会 `NoSuchMethodError`；读可选键 `KEY_PCM_ENCODING` 只能 try/catch（键不存在时抛 NPE）。
- **Android 侧别用 `ArrayList<Float>` 累积采样**：每个采样都要装箱，半小时音轨约 2900 万个，
  手机上直接 OOM。用倍增扩容的 `FloatArray`。同理 C++ 侧别按 buffer 精确 `reserve`，
  那会让每块数据都触发一次实配，退化成 O(n²) 拷贝。
- **Windows 的 MF GUID 常量在 `mfuuid.lib` 里**（`MFMediaType_Audio` / `MFAudioFormat_Float`），
  还要链 `mfplat` / `mfreadwrite` / `ole32`；新增 `.cpp` 必须写进
  `windows/runner/CMakeLists.txt` 的 `add_executable`，否则根本不参与编译。
- **`IMFMediaBuffer::Lock()` 给的指针不保证 4 字节对齐**，取 float 要 `memcpy`，
  不能解引用 `float*`（Dart 侧从通道收字节流时同理，已用 `ByteData` 而非 `Float32List.view`）。
- **线性重采样三端各有一份**（`wav.dart` / Kotlin / C++），必须逐行等价：
  否则同一个非 16 kHz 素材在三端解出不同采样，"Python 端作基准"就只对 16 kHz 素材成立。
- **Dart 3.13 的 `use_null_aware_elements` lint**：集合里写 `if (x != null) x` 会被提示，
  改成 `?x` 才干净（`flutter analyze` 把它算 info，但仓库要求零告警）。
- **`file_picker` 12 换了 API**：没有 `FilePicker.platform` 了，改成静态方法
  `FilePicker.pickFile()`（回 `PlatformFile?`）与 `FilePicker.saveFile()`；后者**要求传字节、
  自己负责落盘**，返回的是 `Uri?` 而不是路径。所以导出流程是「渲染成字符串 → 交给它写」，
  不要自己 `File(path).writeAsString`。
- **导出需要 `files.user-selected.read-write` entitlement**：只给 `read-only` 时，
  保存对话框能选路径但写不进去。这条和「选文件要 read-only」是同一个键的两种级别，
  写权限覆盖读权限，直接用 read-write 即可。
- **沙盒应用只能读自己的容器**：集成测试的素材不能放 `/tmp`。
  模型与测试音频都放在
  `~/Library/Containers/com.voicesmallasr.vsasrApp/Data/Library/Application Support/com.voicesmallasr.vsasrApp/models/`
  下（模型压缩包自带 `test_wavs/`，正好可用）。
- **解析 wav 的 chunk 要按「裁剪后」的长度前进**（2026-08-15 代码审查发现）：
  `data` 的 size 被写成 0（流式写入的 wav）时，按声明值前进等于原地不动，
  循环会把 PCM 数据当成 chunk 头继续解析 —— 采样字节里任意四个恰好拼出 `data`
  就把 data 改指到后面一小片，**静默丢掉大半音频且不报错**。已加回归测试。
- **`ChangeNotifier` 的异步收尾要挡在 `dispose()` 之后**：模型下载/加载要几十秒，
  界面在这期间被销毁时，`dispose()` 看到的 worker 还是 null（什么都没关），
  等 `launch` 返回时 isolate 与 240 MB 模型就漏到了进程结束；而收尾里的
  `notifyListeners()` 还会抛 "used after being disposed"。修法是一个 `_disposed` 标志：
  覆写 `notifyListeners()` 直接返回，并在 await 之后把迟到的 worker 收掉。
- **macOS 的 `AVAssetReaderAudioMixOutput` 只能喂第一条音轨**：把
  `asset.tracks(withMediaType: .audio)` 整个传进去，双语 mp4/mkv 会被 AVFoundation
  混成一条，拿混音去识别就成了鸡尾酒会。Android 取第一条音轨、Windows 用
  `FIRST_AUDIO_STREAM`、Python 端 ffmpeg 默认选流，都是单轨 —— 不统一就等于
  「Python 端作基准」在多音轨容器上不成立。
- **原生解码器绝不能有「不回包」的路径**：Dart 侧 `invokeMethod` 的 future 不会超时，
  一旦漏发 `success`/`error`，界面就永远卡在「正在解码音频…」且按钮全禁用，只能杀进程。
  两处已修：Kotlin 要 `catch (error: Throwable)`（长录音的 `OutOfMemoryError` 是 `Error`
  不是 `Exception`，漏掉它工作线程直接死掉）；Windows 的 `PostMessageW` 失败时
  （窗口已销毁 / 队列满）必须就地回包，不能把 job 丢掉。
- **macOS 缺 `NSMicrophoneUsageDescription` 是直接闪退，不是弹授权框**：系统在进程请求
  麦克风时才检查这条 Info.plist，缺了就 `SIGKILL`。表现是「一点开始录音 app 就没了」，
  控制台里也没有权限相关的报错。它与 entitlements 的 `device.audio-input` 是两回事：
  后者是沙盒开关，两者都要有。
- **不需要 `permission_handler`**：`record` 的 `hasPermission()` 本身就会发起运行时申请
  （Android 弹系统框、macOS/iOS 触发 TCC），多引一个包只会多一套要同步的平台配置。
- **实时会话的定稿段必须排在 `done` 之前到达**：worker 里 `finish()` 的顺序是
  「先把 flush 出来的段 add 进流，再 close」——`await close()` 只会在先前排队的事件
  都送达之后才完成，所以跨 isolate 也不会乱序。反过来先 close 再 add，尾句直接丢掉。
- **录音期间不要挂不定量进度条**：`LinearProgressIndicator()` 会一直调度新帧，
  录音可能持续几十分钟，界面永远处于动画中（widget 测试里表现为 `pumpAndSettle` 超时）。
  只在「准备中/收尾中」这两个过渡态显示。
- **widget 测试里 Stream 的 `close()`/`cancel()` 推不动**：`tester.pump()` 走的是 fake async，
  而这些 Future 只在真实事件循环上完成。停止录音要等麦克风流关闭、识别会话关闭、
  两个订阅取消，因此测试里得 `await tester.runAsync(() => Future.delayed(Duration.zero))`
  走几轮，光 `pumpAndSettle()` 会一直超时。
- **切语言时旧 isolate 还在关，新的不能抢先加载**：`setLanguage` 一把 `_worker` 置空，
  `prepare()` 就会立刻起一个新 isolate，两份 240 MB 模型同时驻留内存，手机上直接爆。
  修法是记下正在关闭的那个 Future，`prepare()` 先 `await` 它。
- **`record` 的 `dispose()` 是终局**：它会销毁平台侧那个录音器实例，之后同一个
  `AudioRecorder` 再 `startStream()` 就失败了。而「开始 → 停止 → 再开始」是最常见的
  用法，所以录音器的生命周期必须是**一场录音**，不能挂在长期存活的对象上。
  替身也要照做 —— 替身若能无限重开，这条路径在测试里就是假的。
- **`dispose()` 里的收尾步骤都要有上限**：worker 关闭时先等实时会话收尾，
  而 isolate 可能卡在某次解码里，`finish()` 永远回不来；不给它设 timeout 的话，
  后面「超时硬杀」那条兜底根本走不到，退出流程直接挂死。

### 网络（中国大陆）

| 目标 | 直连 | 对策 |
| --- | --- | --- |
| `storage.googleapis.com`（Flutter SDK） | ⚠️ 通但极慢 | **实测约 100 KB/s**，`brew install --cask flutter` 下到 260 MB / 11 分钟后放弃；改用腾讯云镜像 **8.4 MB/s**，2.15 GB 用 4.5 分钟下完 |
| `dl.google.com`（Android SDK） | ✅ | 无需镜像 |
| `pub.dev` | ✅ | 无需镜像；**不要设 `PUB_HOSTED_URL`**，指向镜像会把 `pubspec.lock` 里所有包的 url 改写成镜像地址 |
| `mirrors.tuna.tsinghua.edu.cn/flutter` | ❌ 404 | 该镜像已下线，别再试 |
| `maven.google.com`（Gradle 依赖） | ❌ 超时 | 阿里云镜像，已配 |
| `services.gradle.org`（Gradle 224 MB） | ✅ 但慢 | 腾讯云镜像，已配 |
| `github.com`（**模型下载**） | ⚠️ 视机器而定 | 两端均已做三源 fallback，见下 |

**模型下载三源实测（2026-08-15，macOS 机器）**：对 155 MB 的识别模型压缩包各发一次 range 请求，
三个源全部返回 206 并给出真实字节：

| 源 | 结果 | 首 2 MB 速度 |
| --- | --- | --- |
| `github.com` 直连 | ✅ 206 | 106 KB/s |
| `ghfast.top` | ✅ 206 | 304 KB/s |
| `gh-proxy.com` | ✅ 206 | 183 KB/s |

结论：**三个镜像本身都是活的，且在本机比直连 GitHub 更快**。但这是 macOS 机器上的结果，
计划里记录的"github.com 超时"来自那台国内 Windows 机器 —— **国内连通性仍未验证**，
`fallback` 的实战价值要在那台机器上才能确认。第四源（ModelScope / 国内对象存储）暂不加：
它的 URL 结构不是 `<base>/<文件名>`，套不进现有的 `BASE_URLS` 拼接方式，需要单独的取址逻辑。

### 平台限制

- **macOS 安装包只能在 Mac 上构建** —— 本仓库所在的机器就是 Mac，Xcode 26.6 已装，已不是限制。
- **Windows 构建需要开发者模式 + Visual Studio C++ 工具链**，两者都需要管理员权限。
- 蓝牙耳机麦克风是 8 kHz 窄带，识别率明显低于设备自带麦克风。

## 7. 新机器上复现环境

```bash
# Python 端
uv sync --extra mic
uv run vsasr download          # 首次下载模型（约 155 MB 压缩包，三源自动 fallback）
uv run pytest                  # 107 项应全绿；未下模型时集成测试会自动跳过

# Flutter 端（国内先设 SDK 镜像，否则引擎产物下载慢到不可用）
export FLUTTER_STORAGE_BASE_URL=https://mirrors.cloud.tencent.com/flutter
export PATH="$HOME/development/flutter/bin:$PATH"

cd app
flutter pub get
flutter analyze                # 应为 No issues found
flutter test                   # 166 项应全绿（不需要模型、不需要设备）

# macOS 构建前必做一步：把 pub 抹掉的 framework 符号链接补回去（见 §6），
# 否则 codesign 报 "code object is not signed at all"
F=~/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.5/macos/sherpa_onnx_macos/SherpaOnnxC.xcframework/macos-arm64_x86_64/SherpaOnnxC.framework
(cd "$F" && rm -rf Versions/Current Headers Modules Resources SherpaOnnxC \
  && ln -s A Versions/Current \
  && for n in Headers Modules Resources SherpaOnnxC; do ln -s "Versions/Current/$n" "$n"; done)

# 本机无开发证书时验证编译与打包：
(cd macos && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
# 要运行带 Keychain Sharing 的 macOS 包，需要配置开发证书后再执行：
# flutter build macos --debug
flutter run -d macos           # 需 Xcode（本机 26.6 已装）
flutter run -d windows         # 需开发者模式 + VS C++ 工具链
flutter run -d <android-id>    # 需真机或模拟器

# 端到端验收（真模型 + 真引擎 + 真原生解码）。沙盒应用只能读自己的容器，
# 所以先把模型拷进去（Python 端已下过就直接复用）：
SUP="$HOME/Library/Containers/com.voicesmallasr.vsasrApp/Data/Library/Application Support/com.voicesmallasr.vsasrApp/models"
mkdir -p "$SUP" && cp -Rc "$HOME/.cache/voice-small-asr/models/." "$SUP/"
# 顺带造压缩格式与视频素材，用来验原生解码和播放器：
W="$SUP/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/test_wavs"
ffmpeg -y -i "$W/yue.wav" -c:a aac -b:a 128k "$W/yue.m4a"
# 造一个带画面的英文 mp4，用来验播放器、跳转和字幕时间轴：
ffmpeg -y -f lavfi -i color=c=black:s=640x360:r=30:d=8 \
  -i "$W/en.wav" -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 128k \
  -shortest "$W/en.mp4"

flutter test integration_test/e2e_test.dart -d macos   # 7 项应全绿（含真实 en.mp4 播放验收）

# Windows 完整模型 e2e（手动触发；首次下载约 155 MB，成功后由 Actions cache 复用）
gh workflow run windows-build.yml --ref main -f run_full_e2e=true

# 可选：M4 真实第三方 API 英/日视频验收（个人使用可跳过，密钥文件放在仓库外）
WAVS="$SUP/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/test_wavs"
bash scripts/prepare_translation_acceptance_media.sh "$WAVS" "$WAVS"
# 当前集成测试文件仍是旧 DeepL 专用入口；OpenAI-compatible provider 的真实验收
# 需按实际第三方服务商的 endpoint、模型和响应协议另行配置，密钥文件不得入库。

# 生成不含模型、未签名的 macOS Release .app 与 .dmg（需要 Xcode；个人使用不要求发布签名）
FLUTTER_BIN=/path/to/flutter/bin/flutter ./scripts/build_macos_unsigned.sh
```

**别设 `PUB_HOSTED_URL`**：pub.dev 可直连，而指向镜像会让 `flutter pub get` 把
`pubspec.lock` 里 92 个包的 `url` 全部重写成镜像地址并重新解析依赖 —— 那种 lock 不该提交。

Flutter SDK 本身也建议从镜像取（`storage.googleapis.com` 实测约 100 KB/s）：

```bash
curl -L -o flutter.zip \
  https://mirrors.cloud.tencent.com/flutter/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.47.0-stable.zip
unzip -q flutter.zip -d ~/development
```

模型目录：Python 端在 `~/.cache/voice-small-asr/models`（可用 `VSASR_MODEL_DIR` 覆盖），Flutter 端在应用私有目录（`getApplicationSupportDirectory()/models`）。两端目前各存一份，如需共用可在设置页指定路径。

## 8. 主要风险

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| GitHub 模型下载在国内不通，镜像也失效 | 用户装完 App 拿不到模型，功能完全不可用 | 🟡 已降级：三源已实现 fallback、截断校验和解压后 SHA-256 校验；剩余未知是国内网络下的实际可达性，需在国内机器复测。若届时全挂，再接 ModelScope / 国内对象存储作为第四源（需单独取址逻辑） |
| 音频解码方案落空 | M1/M3 返工 | 🟡 已收敛：改为三端各写原生解码并已全部落地（见 §5 已决策 1），Dart 侧分发逻辑有 33 项单测兜底；macOS、Android 模拟器和 Windows CI 完整模型 e2e 已运行验证，用户桌面差异和 Android 真机性能仍待实测 |
| Android 中低端机跑 int8 SenseVoice 太慢 | 实时字幕体验不可用 | 先在真机实测 RTF；必要时降低线程数、增大 VAD 分段、或只在桌面端提供实时功能 |
| 无 Mac 设备 | macOS 端始终无法验证与分发 | 🟡 设备与工具链已具备：Flutter 3.47.0 + Xcode 26.6 + CocoaPods 1.17.0；个人使用的无签名模式编译通过，带 Keychain Sharing 的签名包仅在需要正式签名运行/发布时配置 |
