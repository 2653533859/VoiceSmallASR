# VoiceSmallASR 开发记忆

> 更新时间：2026-08-17

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
- M13 字幕样式与视频配套字幕导出已完成：视频页可调整字号、文字色、背景色和上/中/下位置并持久化；可按视频文件名导出 SRT/VTT/JSON/TXT 配套字幕文件。当前不重新编码硬字幕视频，编码方案留待后续评估。
- M13 文件转写性能诊断已完成：转写控制器分别记录模型准备、解码、识别和总耗时，生成含 RTF、采样点、模型占用、平台和 ASR/VAD 配置的报告；首页支持查看并导出 JSON。模型占用统计未完成时显示“未统计”，不误报为 0。
- M13 批量与实时性能汇总及持续性能历史已完成：批量队列聚合文件数、成功/失败/取消、音频时长、模型准备/解码/识别耗时和 RTF；实时会话记录采样点、音频时长、会话耗时和 RTF；文件、批量和实时报告均支持查看/导出 JSON，并以版本化 JSON 写入应用私有目录，最多保留 100 条，支持清空和跳过损坏条目。
- M5 首期字幕校对编辑已完成：支持文本/时间编辑、合并/拆分、撤销/重做、播放器定位和保存回写；导出前会拒绝重叠、倒序或超出音频时长的时间轴。
- M7 macOS 个人使用打包已完成：`scripts/build_macos_unsigned.sh` 可生成通用 arm64/x86_64 `.app` 与 UDZO `.dmg`，构建产物不含模型；App Store/公证所需的开发者签名不在本项目范围内。
- M7 Android 个人使用构建已完成：本机 Android SDK 36 / Build-Tools 36.1.0 / NDK 28.2.13676358 + JDK 17 成功生成 release APK 和 AAB；APK/AAB 不含模型，未提供签名变量时使用 debug signing，APK 可用于个人安装和测试。
- Android 可选外部签名配置已接入 `app/android/app/build.gradle.kts`：显式提供四个 `VSASR_ANDROID_*` 环境变量时使用外部 keystore，变量不完整或文件不存在会直接失败；JDK 17 与构建链路已验证，本机已用隔离的临时 keystore 构建 APK，`apksigner` v2 校验通过；个人使用不要求开发者 keystore。
- Android 模拟器功能验收已完成：API 35 ARM64 `vsasr-api35` 通过 7 项真实端到端测试，覆盖 Kotlin 原生 m4a 解码、模型识别、media_kit 视频播放/跳转/抽音轨和实时识别；2026-08-16 重跑 7/7，粤语识别 RTF `0.027`；模拟器使用软件渲染，真机性能仍未验证。
- M4 真实验收入口仍可按需扩展：`scripts/prepare_translation_acceptance_media.sh` 生成英/日视频素材；真实第三方 API 网络验收因需要用户自己的服务商密钥，暂不作为当前个人使用交付门禁。
- Windows M7 构建已完成：GitHub Actions run `31912544699` 在 `windows-2022` runner 上通过 MSVC 编译 Flutter Release，并用 `scripts/build_windows_unsigned.ps1` + Inno Setup 生成未签名安装包；CI 自动检查 `vsasr_app.exe`、安装包和四个运行时 DLL，并拒绝模型文件；Release 目录约 111 MiB，安装包约 31 MiB。
- Windows 完整模型 e2e 已验收：GitHub Actions run `31919855391` 在 `windows-2022` 上通过 7 项真实模型/原生解码/播放器/实时识别测试，粤语 wav 识别 RTF `0.064`；同一 workflow 的 Windows smoke、产物校验和 artifact 上传也通过。`.github/workflows/windows-build.yml` 的手动 `run_full_e2e=true` 会恢复模型缓存，必要时通过三源 fallback 下载并做最小字节数校验，再用 `VSASR_MODEL_DIR` 指向外部模型目录运行测试。
- 计划审计已同步修正 `DEVELOPMENT_PLAN.md` §5 的 Windows 解码状态表；个人使用范围内当前未完成项是 Android 真机性能和 Windows 用户桌面运行，第三方 API 真实网络验收已主动跳过。
- 项目定位为个人使用：Android debug-signed APK、macOS 无签名 `.app`/`.dmg` 和 Windows 未签名安装包均属于可接受交付物；Play Store、App Store、公证发布所需的正式证书不在计划范围。
- 三端 GitHub Release 已完成：`.github/workflows/release.yml` 在 run `31995874234` 云端构建并发布 `v1.0.1`，包含 Android APK/AAB、Windows 未签名安装包和 macOS 未签名 DMG/APP 压缩包；发布页为 https://github.com/2653533859/VoiceSmallASR/releases/tag/v1.0.1。
- 当前后续计划见 [`NEXT_DEVELOPMENT_PLAN.md`](NEXT_DEVELOPMENT_PLAN.md)：M8 发布质量基线代码已完成，M9 无签名翻译体验已完成，M10 已完成环境审计但真机/用户桌面验收仍待条件具备，M11 项目保存、字幕导入、首页项目管理、Android SAF、自动保存、异常恢复和媒体重新定位已完成，M12 多文件队列、批量翻译、安全导出、文本缓存与队列恢复已完成，M13 字幕批量时间偏移、搜索替换、阅读速度检查、翻译术语表、服务商预设、字幕样式、视频配套字幕导出、文件转写性能诊断、批量/实时性能汇总、持续性能历史以及手工说话人标签已完成，下一步评估自动说话人分离和硬字幕视频编码。

## 已验证结果

- Python：`pytest` 107 项通过，`ruff check .` 通过。
- Flutter：`flutter analyze` 通过，227 项单测通过；Python 端 107 项测试通过。
- macOS：无签名模式的 `xcodebuild` 已成功编译并打包（含 secure storage plugin）；安全存储不可用时 API Key 退回当前会话，不影响个人使用的无签名包交付。
- M7 打包：已生成 `dist/macos/VoiceSmallASR.app`（通用二进制，约 161 MB）和 `VoiceSmallASR-unsigned.dmg`（约 64 MB），并用 `hdiutil imageinfo` 验证为 UDZO 镜像。
- Android M7 构建：`app/build/app/outputs/flutter-apk/app-release.apk`（169 MiB，177,219,459 bytes）和 `app/build/app/outputs/bundle/release/app-release.aab`（124 MiB，129,974,495 bytes）构建成功；APK 含 arm64-v8a、armeabi-v7a、x86_64，`apksigner verify --verbose` 通过 v2 签名校验，APK/AAB 均未打入 `.onnx`、tar 或 `tokens.txt` 模型文件。
- Windows M7 构建：run `31912544699` 的 `vsasr_app.exe`（141,312 bytes）和 `VoiceSmallASR-unsigned-setup.exe`（32,809,700 bytes）均为 x86-64 PE 文件；Release 目录约 111 MiB，包含 sherpa/ONNX、media_kit 原生 DLL，CI 自动确认未打入 `.onnx`、`.tar`、`.bz2` 或 `tokens.txt` 模型文件。
- Windows 桌面 smoke：run `31914757787` 的 2 项测试通过，验证 Media Foundation AAC 解码，以及 media_kit MP4 打开、读取时长和播放；该 smoke 不加载 ASR 模型。
- Windows 完整模型 e2e：run `31919855391` 的 7 项测试通过，验证模型目录、WAV/m4a 解码、粤语 wav/m4a 识别、真实 mp4 播放/跳转/抽音轨识别和实时识别；粤语 wav RTF `0.064`。
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
- M9 翻译体验已完成：增加第三方数据发送提示、实时字幕单条翻译重试，并确保实时翻译关闭时不会因重试按钮隐式联网。
- M10 环境审计：本机没有 Android 真机或无线设备；最新 Windows Release run `32008744063` 通过构建、analyze、桌面 smoke 和产物校验，Windows 完整模型 E2E 仍引用 run `31919855391`，用户桌面验收未完成。
- M11 项目与外部字幕：新增版本化项目 JSON、配置/字幕/译文/时间轴校验、同目录临时文件保存和控制器快照恢复；首页已支持保存/打开项目与最近项目列表（最多 8 个路径），Android SAF 项目支持字节解析和应用支持目录缓存；新增识别/编辑/配置/翻译后的防抖自动保存、会话锁和启动恢复入口；项目媒体缺失时可重新选择并更新引用；新增 SRT/VTT/JSON 导入、视频外部字幕加载，并复用编辑/翻译/导出链路。
- M12 队列、批量翻译、安全导出、文本缓存与队列恢复：新增批量处理页和顺序多文件转写，支持去重、每文件进度、暂停/继续、取消和失败重试；批量翻译复用同一个 provider 和现有分批/重试逻辑，逐文件显示翻译状态，单项失败不阻塞后续文件，取消通过操作代次阻止迟到译文写回；批量导出支持 SRT/VTT/JSON/TXT，按原媒体文件名生成建议名，同批次重名自动追加序号，用户取消保存后停止后续导出；新增应用私有目录翻译缓存，按媒体路径、源结果、目标语言、endpoint/model 和术语表指纹匹配，命中前确认复用，损坏/不匹配/缺少译文按未命中处理且缓存写入失败不影响翻译；新增批量队列版本化快照、防抖自动保存、退出前强制保存、异常退出恢复/放弃和进行中状态降级；Android SAF 无本地路径时明确拒绝而不静默丢条目；截至当前全量 Flutter 测试 227 项。
- M13 字幕批量时间偏移：字幕编辑器新增整份字幕的正负秒数平移，段级和 token 级时间戳同步移动；复用既有时间轴校验，越过音频边界会拒绝且不改变结果；编辑器页面提供批量偏移入口，支持撤销，新增 3 项回归测试。
- M13 字幕搜索替换：字幕编辑器支持全局文本替换、大小写选项和空替换，文本变化时清除过期译文与 token 时间戳，未命中不产生撤销记录；新增 4 项控制器/页面回归测试。
- M13 阅读速度检查：字幕编辑器按可配置字符/秒阈值检查原文和译文中较长的一行，报告超阈值条目但不改变结果；新增 4 项控制器/页面回归测试，并修复窄窗口工具栏横向溢出。
- M13 翻译术语表：设置页支持每行 `原词=译词` 的可选术语表，保存时校验空值、非法格式和重复原词；文件、实时、视频和批量翻译都会注入术语提示，批量缓存 scope 包含术语表；新增 provider、设置持久化和设置页回归测试。
- M13 服务商预设：设置页支持保存、选择和删除 endpoint、模型、目标语言和术语表组合；预设不包含 API Key，损坏条目跳过，自定义目标语言可恢复；新增模型序列化、持久化和设置页回归测试。
- M13 字幕样式与视频配套字幕导出：视频页新增样式配置和持久化，以及按视频文件名导出 SRT/VTT/JSON/TXT 的入口；新增设置持久化和视频页回归测试，硬字幕视频编码仍待跨平台方案。
- M13 文件转写性能诊断：新增性能报告值对象和首页入口，记录模型准备、解码、识别、RTF、采样点、平台、模型占用与 ASR/VAD 配置；支持查看和导出 JSON，新增控制器与首页回归测试。
- M13 批量与实时性能汇总：新增批量聚合报告和实时会话报告，两个页面均支持查看/导出 JSON；新增批量、实时控制器和页面回归测试。
- M13 持续性能历史：新增版本化性能日志存储，文件、批量和实时报告写入应用私有目录，最多保留 100 条；首页/实时字幕页支持查看和清空历史，损坏条目单独跳过；新增存储、首页和实时字幕回归测试。
- M13 手工说话人标签：`Segment`/项目 JSON 支持可选标签；字幕编辑器支持编辑和清空，合并时仅在两段标签一致时保留，拆分时传播到两段；SRT/VTT/TXT 使用明确的 `[speaker:标签]` 标记，视频叠加和字幕列表显示 `【标签】`；自动说话人分离与硬字幕视频编码仍待后续评估。

## 尚未验证的环境

- Android 原生 Kotlin 解码已在 API 35 ARM64 模拟器端到端运行验证，但尚未在真机运行。
- Windows 原生 C++ 解码已在 MSVC/Windows SDK 上编译，并在 CI 桌面 smoke 与完整模型 e2e 中通过 AAC/视频音轨识别；用户桌面运行仍未验证。
- Android 模拟器的 media_kit 视频播放已通过端到端验证；Windows CI smoke 已通过 media_kit MP4 打开、读取时长和播放，用户桌面差异仍未验证。
- Android 实时字幕的中低端设备性能尚未测量。

## 工作约定

每个开发计划项按“实现 → 代码审查 → 修复 → 相关测试 → 更新本文件和 `DEVELOPMENT_PLAN.md` → 提交推送”推进。
