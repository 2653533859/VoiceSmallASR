# VoiceSmallASR 开发记忆

> 更新时间：2026-08-18

## 当前阶段

- Python 端已完成：离线多语种识别、CLI、VAD 流式识别、时间戳和字幕导出。
- Flutter 端已完成 M1（文件转写 + 字幕导出）和 M2（麦克风实时字幕）的 macOS 闭环。
- M3 已完成：跨平台视频播放器、字幕叠加、播放进度联动与点击字幕跳转，真实英文 `en.mp4` 已在 macOS 端到端验收。
- M4 的第一项已完成：加入服务商无关的 `TranslationProvider` 和 `translateResult()`，可在校验返回数量后把译文安全写入 `Segment.translation`。
- M4 的批量流程已完成：`translateResult()` 支持分批、失败重试、延迟和累计进度回报，全部批次成功后才写回译文。
- M4 的双语字幕导出已完成：SRT/VTT/TXT 输出原文与译文双行，JSON 保留结构化译文；带译文的长段不切分以保持时间边界一致。
- M4 的首期在线 provider 已完成：`ApiTranslationProvider` 支持可配置的 OpenAI-compatible 第三方 Chat Completions API，包含 endpoint、模型、API Key、错误脱敏和响应数量校验。
- M4 的应用内翻译工作流已完成：文件转写页和视频播放页从安全存储读取第三方翻译 API Key，显示批量进度，成功后回写译文，失败时保留原结果；实时字幕页支持逐条翻译，单次录音会话复用 provider，停止时取消未开始的排队请求，译文会显示在列表、视频叠加字幕并进入后续导出链路。
- M6 首期设置页与模型管理已完成：语言、线程数、ITN、临时结果间隔、VAD 断句参数、第三方翻译 endpoint/模型/API Key 可保存；普通设置/离线模式用 `shared_preferences`，API Key 用 `flutter_secure_storage`，启动时恢复配置；设置页支持模型下载、删除与占用空间显示。
- M13 翻译术语表已完成：设置页支持每行 `原词=译词` 的可选术语表，保存和 provider 构造时校验非法格式/重复原词；文件、实时、视频和批量翻译都会注入术语提示，批量缓存 scope 包含术语表内容。
- M13 服务商预设已完成：设置页可保存、选择和删除 endpoint、模型、目标语言和术语表组合；预设以普通设置 JSON 持久化，不包含 API Key；加载时跳过损坏或重复条目，并支持自定义目标语言。
- M10 API 35 ARM64 模拟器性能基线已补充：统一验收入口通过模型下载、完整性校验和 `yue.wav` 文件识别，2 线程文件 RTF `0.026612`，模型目录约 241 MB，模型准备后 RSS 当前约 403 MiB、峰值约 447 MiB；随后用 H.264+AAC MP4 通过音轨解码、播放器打开和播放推进（528 ms / 146 ms / 3.021 s），麦克风参数未提供而明确跳过。另一次麦克风补充验收在权限完成后计时，5 秒请求实际采集 4.928 秒，会话耗时 5,031 ms，RTF `1.020901`，未持续积压，但模拟器没有人工讲话而未产生字幕段。首次慢速下载曾触发 test_api 默认 12 分钟超时，入口现改为 30 分钟库级超时并按约 1 MiB 节流下载日志；该结果不替代 Android 真机或厂商差异验收，记录见 [`M10_DEVICE_ACCEPTANCE.md`](M10_DEVICE_ACCEPTANCE.md)。
- M10 模型下载三源当前主机复测：2026-08-18 在本机 macOS 对识别模型前 2 MiB 发起分段请求，GitHub、`ghfast.top`、`gh-proxy.com` 均返回 HTTP `206` 和完整字节，速度约为 360,833 / 437,475 / 317,526 B/s；这不等于国内 Windows 网络验收，仍保留三源 fallback，记录见 [`M10_DEVICE_ACCEPTANCE.md`](M10_DEVICE_ACCEPTANCE.md)。
- M13 字幕样式、视频配套字幕导出与桌面/Android 硬字幕编码已完成：视频页可调整字号、文字色、背景色和上/中/下位置并持久化；可按视频文件名导出 SRT/VTT/JSON/TXT 配套字幕文件；桌面调用本机 FFmpeg/ASS，Android 调用 MediaCodec + OpenGL + MediaMuxer 生成带原文、译文和说话人标签的 MP4，Android 支持 AAC 音轨直通、系统可解码的非 AAC 音轨转 AAC 和 API 26+ SAF 输出。新增 MethodChannel 单测、视频页回归测试和跨平台真实验收脚本；API 35 ARM64 模拟器已真实通过 H.264+AAC、H.264+MP3、VP9+Opus、HEVC+AAC、AV1+AAC 和 VP8+Vorbis，Windows CI run `32056120388` 已用 `ffmpeg-full` 通过 `ass/libass` 硬字幕 smoke；macOS `ffmpeg-full 9.0.1` 已通过纯 VM 与无开发证书 ad-hoc Debug Runner 集成验收；普通 Homebrew FFmpeg 8.1.1 缺少 `libass` 时已通过预期失败验收，记录见 [`M13_FFMPEG_COMPATIBILITY.md`](M13_FFMPEG_COMPATIBILITY.md)；真实 Android 设备、厂商 Codec 差异和 Windows 用户桌面仍待验收。
- M13 文件转写性能诊断已完成：转写控制器分别记录模型准备、解码、识别和总耗时，生成含 RTF、采样点、模型占用、平台和 ASR/VAD 配置的报告；首页支持查看并导出 JSON。模型占用统计未完成时显示“未统计”，不误报为 0。
- M13 批量与实时性能汇总及持续性能历史已完成：批量队列聚合文件数、成功/失败/取消、音频时长、模型准备/解码/识别耗时和 RTF；实时会话记录采样点、音频时长、会话耗时和 RTF；文件、批量和实时报告均支持查看/导出 JSON，并以版本化 JSON 写入应用私有目录，最多保留 100 条，支持清空和跳过损坏条目。
- M5 首期字幕校对编辑已完成：支持文本/时间编辑、合并/拆分、撤销/重做、播放器定位和保存回写；导出前会拒绝重叠、倒序或超出音频时长的时间轴。
- M7 macOS 个人使用打包已完成：`scripts/build_macos_unsigned.sh` 可生成通用 arm64/x86_64 `.app` 与 UDZO `.dmg`，构建产物不含模型；App Store/公证所需的开发者签名不在本项目范围内。
- M7 Android 个人使用构建已完成：本机 Android SDK 36 / Build-Tools 36.1.0 / NDK 28.2.13676358 + JDK 17 成功生成 release APK 和 AAB；APK/AAB 不含模型，未提供签名变量时使用 debug signing，APK 可用于个人安装和测试。
- Android 可选外部签名配置已接入 `app/android/app/build.gradle.kts`：显式提供四个 `VSASR_ANDROID_*` 环境变量时使用外部 keystore，变量不完整或文件不存在会直接失败；JDK 17 与构建链路已验证，本机已用隔离的临时 keystore 构建 APK，`apksigner` v2 校验通过；个人使用不要求开发者 keystore。
- Android 模拟器功能验收已完成：API 35 ARM64 `vsasr-api35` 通过 7 项真实端到端测试，覆盖 Kotlin 原生 m4a 解码、模型识别、media_kit 视频播放/跳转/抽音轨和实时识别；2026-08-16 重跑 7/7，粤语识别 RTF `0.027`；模拟器使用软件渲染，真机性能仍未验证。
- Android release APK 安装启动基线已补齐：2026-08-18 在 API 35 ARM64 `emulator-5554` 实际安装并冷启动 `versionName=1.0.2`、`versionCode=999` 的约 178.6 MB APK，v2 签名和模型排除通过，清除旧数据后进程稳定运行 8 秒；复用脚本 `scripts/android_apk_install_smoke.sh`，该结果仍不等于 Android 真机性能/内存/RTF 或厂商 Codec 验收。
- M4 真实验收入口仍可按需扩展：`scripts/prepare_translation_acceptance_media.sh` 生成英/日视频素材；真实第三方 API 网络验收因需要用户自己的服务商密钥，暂不作为当前个人使用交付门禁。
- Windows M7 构建已完成：GitHub Actions run `31912544699` 在 `windows-2022` runner 上通过 MSVC 编译 Flutter Release，并用 `scripts/build_windows_unsigned.ps1` + Inno Setup 生成未签名安装包；CI 自动检查 `vsasr_app.exe`、安装包和四个运行时 DLL，并拒绝模型文件；Release 目录约 111 MiB，安装包约 31 MiB。
- Windows 完整模型 e2e 已验收：GitHub Actions run `31919855391` 在 `windows-2022` 上通过 7 项真实模型/原生解码/播放器/实时识别测试，粤语 wav 识别 RTF `0.064`；同一 workflow 的 Windows smoke、产物校验和 artifact 上传也通过。`.github/workflows/windows-build.yml` 的手动 `run_full_e2e=true` 会恢复模型缓存，必要时通过三源 fallback 下载并做最小字节数校验，再用 `VSASR_MODEL_DIR` 指向外部模型目录运行测试。
- Windows 最新完整模型 e2e 已复验：run `32075654714` 在 `windows-2022` 上通过 7 项测试，粤语 WAV RTF `0.055`，实时识别定稿 4 句、局部结果 4 条；覆盖模型目录、WAV/m4a 原生解码、真实 MP4 播放/跳转/抽音轨识别和实时识别，同一 run 的桌面 smoke、硬字幕 smoke、Release 构建、运行时依赖、模型排除和 artifact 上传也通过。该 run 使用 Windows Actions 模型缓存和 `VSASR_MODEL_DIR`，仍不等于 Windows 用户桌面手工验收。
- Windows 安装包 CI smoke 已补齐：run `32078081707` 将未签名安装包静默安装到空目录，验证 `vsasr_app.exe`、四个运行时 DLL 和模型排除，并用隔离 `APPDATA`/`LOCALAPPDATA` 启动已安装程序保持运行 8 秒；CI 产物安装/首次启动已自动化，但仍不等于用户自己的 Windows 桌面手工验收。
- Windows 硬字幕 CI 验收已完成：run `32048430484` 在 `windows-2022` 上安装 `ffmpeg-full`，确认 `ass/libass` 滤镜可用，并通过真实 `tone.mp4` 的桌面 smoke、硬字幕编码 smoke、Release 构建、运行时 DLL 和模型排除检查；此前 run `32047737222`/`32048080173` 暴露并修复了 essentials FFmpeg 不含 libass 和检查表达式不稳的问题。
- 计划审计已同步修正 `DEVELOPMENT_PLAN.md` §5 的 Windows 解码状态表；个人使用范围内当前未完成项是 Android 真机性能和 Windows 用户桌面运行，第三方 API 真实网络验收已主动跳过。
- 项目定位为个人使用：Android debug-signed APK、macOS 无签名 `.app`/`.dmg` 和 Windows 未签名安装包均属于可接受交付物；Play Store、App Store、公证发布所需的正式证书不在计划范围。
- 三端 GitHub Release 已完成：`.github/workflows/release.yml` 在 run `31995874234` 云端构建并发布 `v1.0.1`，随后由 run [`32082049856`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32082049856) 构建并更新 `v1.0.2`，包含 Android APK/AAB、Windows 未签名安装包、macOS 未签名 DMG/APP 压缩包、`SHA256SUMS.txt` 和 `BUILD_INFO.txt`；本次资产对应提交 `5d64f49`，发布页为 https://github.com/2653533859/VoiceSmallASR/releases/tag/v1.0.2。
- 当前后续计划见 [`NEXT_DEVELOPMENT_PLAN.md`](NEXT_DEVELOPMENT_PLAN.md)：M8 发布质量基线和 `v1.0.2` 云端全流程 Release 已完成，M9 无签名翻译体验已完成，M10 已补齐 Windows CI 的桌面/硬字幕自动验收以及 Android/Windows 统一 device acceptance 入口和执行手册，但 Android 真机和 Windows 用户桌面验收仍待条件具备，M11 项目保存、字幕导入、首页项目管理、Android SAF、自动保存、异常恢复和媒体重新定位已完成，M12 多文件队列、批量翻译、安全导出、文本缓存与队列恢复已完成，M13 字幕批量时间偏移、搜索替换、阅读速度检查、翻译术语表、服务商预设、字幕样式、视频配套字幕导出、桌面/Android 硬字幕编码、文件转写性能诊断、批量/实时性能汇总、持续性能历史、手工和自动说话人分离已完成；自动说话人分离的 macOS 真实模型验收记录见 [`M13_DIARIZATION_ACCEPTANCE.md`](M13_DIARIZATION_ACCEPTANCE.md)；下一步完成 Android 真机性能、Windows 用户桌面和其他平台兼容性验收。

## 已验证结果

- Python：`pytest` 107 项通过，`ruff check .` 通过。
- Flutter：`flutter analyze` 通过，234 项单测通过；Python 端 107 项测试通过。
- macOS：无签名模式的 `xcodebuild` 已成功编译并打包（含 secure storage plugin）；安全存储不可用时 API Key 退回当前会话，不影响个人使用的无签名包交付。
- M13 自动说话人分离真实模型验收：macOS 26.5.2 arm64 Debug Runner 使用 ad-hoc 签名通过官方 `0-four-speakers-zh.wav`、pyannote segmentation 和 3D-Speaker embedding 的端到端验收；模型文件只存在于临时目录，SHA-256 与输出时间段契约均通过，详细命令和范围见 [`M13_DIARIZATION_ACCEPTANCE.md`](M13_DIARIZATION_ACCEPTANCE.md)。
- M7 打包：已生成 `dist/macos/VoiceSmallASR.app`（通用二进制，约 161 MB）和 `VoiceSmallASR-unsigned.dmg`（约 64 MB），并用 `hdiutil imageinfo` 验证为 UDZO 镜像。
- Android M7 构建：`app/build/app/outputs/flutter-apk/app-release.apk`（169 MiB，177,219,459 bytes）和 `app/build/app/outputs/bundle/release/app-release.aab`（124 MiB，129,974,495 bytes）构建成功；APK 含 arm64-v8a、armeabi-v7a、x86_64，`apksigner verify --verbose` 通过 v2 签名校验，APK/AAB 均未打入 `.onnx`、tar 或 `tokens.txt` 模型文件。
- Windows M7 构建：run `31912544699` 的 `vsasr_app.exe`（141,312 bytes）和 `VoiceSmallASR-unsigned-setup.exe`（32,809,700 bytes）均为 x86-64 PE 文件；Release 目录约 111 MiB，包含 sherpa/ONNX、media_kit 原生 DLL，CI 自动确认未打入 `.onnx`、`.tar`、`.bz2` 或 `tokens.txt` 模型文件。
- Windows 桌面 smoke：run `31914757787` 的 2 项测试通过，验证 Media Foundation AAC 解码，以及 media_kit MP4 打开、读取时长和播放；该 smoke 不加载 ASR 模型。
- Windows 完整模型 e2e：run `31919855391` 的 7 项测试通过，验证模型目录、WAV/m4a 解码、粤语 wav/m4a 识别、真实 mp4 播放/跳转/抽音轨识别和实时识别；粤语 wav RTF `0.064`。
- Windows 硬字幕 CI：run `32048430484` 的 `ass/libass` 能力检查、无模型桌面 smoke、真实硬字幕 MP4 编码 smoke、产物校验和 artifact 上传全部通过。
- Android API 35 模拟器 e2e：2026-08-16 重跑 7 项全部通过，真实模型识别结果与 Python 基线一致，RTF `0.027`；该结果仅作为模拟器基线，不代表真机性能。
- 播放器：`media_kit 1.2.6` + `media_kit_video 2.0.1` + `media_kit_libs_video 1.0.7` 已接入；macOS 无签名编译通过，插件当前由 CocoaPods 集成。
- M3 测试覆盖：播放器状态/生命周期、字幕时间边界、视频页加载/叠加/点击跳转；7 项集成测试包含真实 `en.mp4` 播放、跳转、抽音轨和识别。
- M4 测试覆盖：翻译抽象/批量流程、双语导出、旧 DeepL provider 兼容、第三方 API provider、文件页/视频页/实时字幕翻译测试。
- 双语字幕导出测试：4 项，覆盖 SRT/VTT/TXT/JSON、译文顺序、关闭双语和长段时间边界。
- M6 测试覆盖：3 项 API Key 安全存储测试、4 项普通设置/离线模式持久化测试、2 项设置页测试、1 项配置变更后 worker 重启测试，以及 4 项模型/worker 生命周期测试。
- M5 测试覆盖：9 项字幕编辑器、页面交互和导出时间轴校验测试。
- M4 翻译工作流新增状态机、文件页、视频页和实时字幕翻译测试；真实第三方 API 网络验收按个人使用范围主动跳过。
- macOS 真模型端到端验收已完成：Flutter 与 Python 对粤语素材逐字一致，实时识别链路的定稿序号和时间戳连续。

## 最近修复

- 同步 `record 7.1.1` 的 `hasPermission({bool request})` 测试替身签名。
- Flutter 模型下载的连接和响应流增加 60 秒超时，超时后切换镜像源。
- 实时会话收尾时用 `finally` 释放 VAD 原生资源。
- Windows Media Foundation 解码线程增加异常和线程创建失败兜底，确保 MethodChannel 回包。
- 播放器异步操作在页面销毁后不再访问已销毁的状态对象；无扩展名路径判断视频时不再越界。
- `media_kit` 集成测试先挂载真实 `Video` 完成首帧初始化，再调用播放器 `open()`；英文素材按首个有效字幕段验证，避免假设整段只有一个 cue。
- Windows 完整 e2e 模型准备改为多源下载、每源有限重试、最低 256 KiB/s 低速超时、最小文件大小校验、Actions cache 和 7-Zip 分层解压；`VSASR_MODEL_DIR` 仅在显式设置时覆盖默认应用私有模型目录。
- Windows 完整模型 e2e 使用 expanded reporter，避免默认 GitHub reporter 在 Windows 测试收尾时仅显示退出码而隐藏实际测试进度。
- v1.0.2 稳定化修复：实时字幕测试改为有限帧推进，实时控制器无翻译任务时不等待空队列；无签名 macOS 安全存储不可用时 API Key 仅保留当前会话；Python/Flutter 模型缓存增加解压后 SHA-256 校验；Release workflow 增加 Python/Flutter 质量门禁并从 Tag 注入三端版本。
- M8 发布质量基线已落地：`scripts/verify_model_exclusion.sh` 及各平台 workflow 检查最终产物不含模型，macOS 额外挂载 DMG 检查；Release job 生成 `SHA256SUMS.txt`/`BUILD_INFO.txt`。模型完整性失败会清理旧压缩包，避免重复复用坏缓存。
- CI 运行时维护：2026-08-18 将 `release.yml` 与 `windows-build.yml` 的 GitHub Actions 升级到 Node 24 兼容版本（`checkout@v7`、`setup-python@v7`、`setup-java@v5`、`setup-uv@v10`、`cache@v6`、`upload-artifact@v7`、`download-artifact@v8`），用于消除 runner 的 Node 20 弃用警告；升级后的构建结果待本次 push CI 确认。
- M9 翻译体验已完成：增加第三方数据发送提示、实时字幕单条翻译重试，并确保实时翻译关闭时不会因重试按钮隐式联网。
- M10 环境审计：本机没有 Android 真机或无线设备；API 35 ARM64 模拟器已通过统一入口的模型完整性、文件识别、H.264+AAC 视频解码/播放和麦克风采样基线，文件 RTF `0.026612`，视频音轨解码/播放器打开/时长为 528 ms / 146 ms / 3.021 s，麦克风 RTF `1.020901` 且未持续积压；模拟器无人工讲话，因此不能替代真机性能、语音质量或厂商差异。Windows 最新 CI run `32048430484` 已通过 analyze、`ffmpeg-full`/`ass` 检查、桌面 smoke、硬字幕编码 smoke、构建和产物校验，完整模型 E2E 仍由 run `31919855391` 提供依据；Android 真机性能和 Windows 用户桌面验收未完成。
- M10 验收入口：新增 `app/integration_test/device_acceptance_test.dart`，模型缺失时实际下载并校验，使用模型自带 `yue.wav` 记录文件 RTF，按需测视频播放和真实麦克风实时积压，通过 `dart:io ProcessInfo` 记录各阶段进程 RSS 当前值/峰值，并保存可选设备标识、实际语言和线程配置；入口库级超时调整为 30 分钟，下载进度按约 1 MiB 节流，避免慢速首次下载被默认 12 分钟超时或日志刷屏；麦克风 RTF 现在从录音流建立、权限完成后开始计时，不把系统权限等待算作识别耗时。新增 [`M10_DEVICE_ACCEPTANCE.md`](M10_DEVICE_ACCEPTANCE.md) 区分自动化报告与安装包手工清单。API 35 ARM64 模拟器基线已通过，文件 RTF `0.026612`，H.264+AAC 视频音轨解码/播放器打开/时长为 528 ms / 146 ms / 3.021 s，麦克风补充基线 RTF `1.020901` 且未持续积压；`dart analyze`、`flutter analyze --no-pub`、模型管理单测 2/2 和 Flutter 全量测试 234 项通过，提交 `cce0412` 的 Windows 回归 run `32052413073` 通过，真实 Android/Windows 用户桌面数据仍未完成。
- M10 Android 发布包自动验收：`release.yml` 已在 Android APK/AAB 产物校验后接入 API 35 `google_apis` x86_64 模拟器，复用 `scripts/android_apk_install_smoke.sh` 完成清数据、安装、冷启动和 8 秒进程存活检查，Android job 总时限 30 分钟；本地 API 35 模拟器已通过，手动 `v1.0.2` 发布 run [`32082049856`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32082049856) 也全部通过并将 Release 资产更新到提交 `5d64f49`，仍不替代 Android 真机验收。
- M11 项目与外部字幕：新增版本化项目 JSON、配置/字幕/译文/时间轴校验、同目录临时文件保存和控制器快照恢复；首页已支持保存/打开项目与最近项目列表（最多 8 个路径），Android SAF 项目支持字节解析和应用支持目录缓存；新增识别/编辑/配置/翻译后的防抖自动保存、会话锁和启动恢复入口；项目媒体缺失时可重新选择并更新引用；新增 SRT/VTT/JSON 导入、视频外部字幕加载，并复用编辑/翻译/导出链路。
- M12 队列、批量翻译、安全导出、文本缓存与队列恢复：新增批量处理页和顺序多文件转写，支持去重、每文件进度、暂停/继续、取消和失败重试；批量翻译复用同一个 provider 和现有分批/重试逻辑，逐文件显示翻译状态，单项失败不阻塞后续文件，取消通过操作代次阻止迟到译文写回；批量导出支持 SRT/VTT/JSON/TXT，按原媒体文件名生成建议名，同批次重名自动追加序号，用户取消保存后停止后续导出；新增应用私有目录翻译缓存，按媒体路径、源结果、目标语言、endpoint/model 和术语表指纹匹配，命中前确认复用，损坏/不匹配/缺少译文按未命中处理且缓存写入失败不影响翻译；新增批量队列版本化快照、防抖自动保存、退出前强制保存、异常退出恢复/放弃和进行中状态降级；Android SAF 无本地路径时明确拒绝而不静默丢条目；截至当前全量 Flutter 测试 234 项。
- M13 字幕批量时间偏移：字幕编辑器新增整份字幕的正负秒数平移，段级和 token 级时间戳同步移动；复用既有时间轴校验，越过音频边界会拒绝且不改变结果；编辑器页面提供批量偏移入口，支持撤销，新增 3 项回归测试。
- M13 字幕搜索替换：字幕编辑器支持全局文本替换、大小写选项和空替换，文本变化时清除过期译文与 token 时间戳，未命中不产生撤销记录；新增 4 项控制器/页面回归测试。
- M13 阅读速度检查：字幕编辑器按可配置字符/秒阈值检查原文和译文中较长的一行，报告超阈值条目但不改变结果；新增 4 项控制器/页面回归测试，并修复窄窗口工具栏横向溢出。
- M13 翻译术语表：设置页支持每行 `原词=译词` 的可选术语表，保存时校验空值、非法格式和重复原词；文件、实时、视频和批量翻译都会注入术语提示，批量缓存 scope 包含术语表；新增 provider、设置持久化和设置页回归测试。
- M13 服务商预设：设置页支持保存、选择和删除 endpoint、模型、目标语言和术语表组合；预设不包含 API Key，损坏条目跳过，自定义目标语言可恢复；新增模型序列化、持久化和设置页回归测试。
- M13 字幕样式、视频配套字幕导出与桌面/Android 硬字幕编码：视频页新增样式配置和持久化，以及按视频文件名导出 SRT/VTT/JSON/TXT 的入口；桌面可调用本机 FFmpeg/ASS，Android 通过 MediaCodec + OpenGL + MediaMuxer 生成 MP4，AAC 音轨直通，系统可解码的非 AAC 音轨先转 AAC；新增编码器 MethodChannel 单测、视频页回归测试和跨平台真实编码验收脚本；API 35 ARM64 模拟器已通过六种输入，Windows CI run `32048430484` 已通过 `ffmpeg-full`/`ass` 硬字幕 smoke，普通 Homebrew FFmpeg 缺少 `libass` 的预期失败也已通过；真实 Android 设备、厂商 Codec 差异和 Windows 用户桌面仍待环境具备。
- M13 文件转写性能诊断：新增性能报告值对象和首页入口，记录模型准备、解码、识别、RTF、采样点、平台、模型占用与 ASR/VAD 配置；支持查看和导出 JSON，新增控制器与首页回归测试。
- M13 批量与实时性能汇总：新增批量聚合报告和实时会话报告，两个页面均支持查看/导出 JSON；新增批量、实时控制器和页面回归测试。
- M13 持续性能历史：新增版本化性能日志存储，文件、批量和实时报告写入应用私有目录，最多保留 100 条；首页/实时字幕页支持查看和清空历史，损坏条目单独跳过；新增存储、首页和实时字幕回归测试。
- M13 手工说话人标签与自动说话人分离：保留手工标签编辑能力；新增 pyannote segmentation + 3D-Speaker embedding 模型管理、sha256 校验、后台 isolate 推理、按时间重叠映射 `SPEAKER_00` 等标签，以及首页自动估计/指定人数入口。新增 4 项单测和显式真实模型验收脚本；本机 macOS 已使用官方四人中文 WAV 通过自动分离真实模型验收，记录见 [`M13_DIARIZATION_ACCEPTANCE.md`](M13_DIARIZATION_ACCEPTANCE.md)；Android 真机与 Windows 用户桌面验收待环境具备。桌面/Android 硬字幕编码代码已完成，Android API 35 模拟器已通过 AAC 直通和 MP3 转 AAC 真实编码。

## 尚未验证的环境

- M13 macOS 硬字幕补充验收：新增 `app/tool/hard_subtitle_ffmpeg_acceptance_test.dart`，使用本机 `ffmpeg-full 9.0.1` 直接调用生产编码器生成 MP4，并由 FFmpeg 重新解码；无开发证书的 Debug Runner 通过 ad-hoc 签名完成集成启动与真实编码验收。普通 Homebrew FFmpeg 8.1.1 不含 `libass`，已通过显式预期失败模式确认应用返回可操作提示；桌面硬字幕仍需使用包含 ASS/libass 的 FFmpeg，详细记录见 [`M13_FFMPEG_COMPATIBILITY.md`](M13_FFMPEG_COMPATIBILITY.md)。

- M13 编解码器矩阵补充验收：API 35 ARM64 模拟器已通过 H.264+AAC、H.264+MP3、VP9+Opus、HEVC+AAC、AV1+AAC、VP8+Vorbis 六种输入；同一集成测试入口现支持 `VSASR_HARD_SUBTITLE_TEST_VIDEOS` 的 `|` 分隔路径，详细记录见 [`M13_CODEC_ACCEPTANCE.md`](M13_CODEC_ACCEPTANCE.md)。该结果仍不代表 Android 真机或厂商 Codec 兼容性。

- Android 原生 Kotlin 解码和硬字幕编码已完成编译；解码与硬字幕编码均已在 API 35 ARM64 模拟器端到端运行验证，但尚未在真实 Android 设备运行。
- Windows 原生 C++ 解码已在 MSVC/Windows SDK 上编译，并在 CI 桌面 smoke、完整模型 e2e 和硬字幕 smoke 中通过 AAC/视频音轨识别与 MP4 编码；用户桌面运行仍未验证。
- Android 模拟器的 media_kit 视频播放已通过端到端验证；Windows CI smoke 已通过 media_kit MP4 打开、读取时长和播放，用户桌面差异仍未验证。
- Android 实时字幕的中低端设备性能尚未测量。

## 工作约定

每个开发计划项按“实现 → 代码审查 → 修复 → 相关测试 → 更新本文件和 `DEVELOPMENT_PLAN.md` → 提交推送”推进。
