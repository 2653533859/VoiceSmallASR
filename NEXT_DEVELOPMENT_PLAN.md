# VoiceSmallASR 后续开发计划

> 更新日期：2026-08-18　　基线版本：v1.0.2　　下一目标：v1.0.3

本计划建立在三端个人使用版本已经可以打包发布的基础上。后续优先保证安装包可验证、无签名环境可用，再增加项目管理和批量处理能力。

## 当前基线

- Python 端：离线多语种识别、CLI、实时 VAD、时间戳和字幕导出已完成；`pytest` 107 项通过。
- Flutter 端：文件转写、实时字幕、视频播放、字幕编辑、双语导出、第三方 API 翻译、设置页和模型管理已完成；项目文件数据层、首页保存/打开、最近项目、Android SAF 字节读取、自动保存、异常恢复、媒体缺失重新定位、SRT/VTT/JSON 字幕导入和 M12 多文件队列/批量翻译/安全导出/文本缓存/队列恢复已接入；M13 已加入字幕批量时间偏移、搜索替换、阅读速度检查、翻译术语表、服务商预设、播放器字幕样式、视频配套字幕导出、桌面与 Android 硬字幕视频编码、文件转写性能诊断、批量/实时性能汇总报告、持续性能历史和自动说话人分离；`flutter analyze` 与 `flutter test` 234 项通过。
- 平台验收：macOS ASR 与自动说话人分离真实模型、Android API 35 模拟器识别/播放与硬字幕编码、Windows CI 完整模型 E2E/桌面 smoke/硬字幕编码已通过；Android 真机和 Windows 用户桌面仍待验收。
- 发布能力：`v1.0.2` 已发布 Android APK/AAB、Windows 未签名安装包和 macOS 未签名 DMG/ZIP，并上传 `SHA256SUMS.txt` 与 `BUILD_INFO.txt`。
- 明确范围：个人使用，不做商店发布、公证和正式签名证书；真实第三方翻译 API 网络验收不作为自动化门禁。

## 已完成的稳定化修复

本轮已经落地以下问题修复：

1. 实时字幕 Widget 测试改为有限帧推进，避免常驻动画导致 `pumpAndSettle` 无限等待。
2. 实时控制器没有翻译任务时不再等待空翻译队列，测试和页面销毁可以正常收尾。
3. 无签名 macOS 无法使用系统安全存储时，API Key 退回当前会话内存，不写入普通配置或明文文件。
4. Python 与 Flutter 在模型最终加载前校验固定文件的 SHA-256，截断、损坏或错误代理响应不会直接进入推理。
5. Release workflow 增加 Python/Flutter 质量门禁，并把 Release Tag 注入 Android、macOS、Windows 的应用版本。

## M8 · 发布质量基线（v1.0.2，代码已落地）

目标：任何新 Tag 都必须经过自动检查，并且安装包内部版本与 Tag 一致。

已完成：

- Python `pytest`、Ruff、Flutter analyze 和 Flutter 单元测试已作为 Release 前置质量门禁。
- 实时字幕测试改为有限帧推进，控制器销毁会等待真实翻译任务并释放资源。
- Android APK/AAB、macOS App/ZIP/DMG、Windows Release 目录均加入模型排除检查。
- GitHub Release job 会生成 `SHA256SUMS.txt` 和 `BUILD_INFO.txt`，记录产物校验和、提交、工作流和构建编号。
- 发布说明已区分“识别离线能力”和“用户主动启用的在线翻译能力”。
- 模型完整性失败时会清理旧解压目录、VAD 文件和压缩包，下一次允许重新下载。

当前状态：代码、本地验证和云端 `v1.0.2` Release 已完成；GitHub Actions run [`32082049856`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32082049856) 的质量门禁、三端构建、Android API 35 模拟器安装启动、产物校验和 Release 更新全部通过，Release 资产对应提交 `5d64f49`。

- 2026-08-18 已将 `release.yml` 与 `windows-build.yml` 的 GitHub Actions 运行时升级到 Node 24 兼容版本：`checkout@v7`、`setup-python@v7`、`setup-java@v5`、`setup-uv@v10`、`cache@v6`、`upload-artifact@v7` 和 `download-artifact@v8`；push CI [`32083961892`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32083961892) 已通过，构建、硬字幕 smoke、安装包首次启动和 artifact 上传均保持成功，且不再出现 Node 20 弃用警告。
- 2026-08-18 完成文档基线审计：`CLAUDE.md` 的 Flutter 测试数更新为 234 项并补齐 M13 能力，`README.md` 更新到 `v1.0.2` 发布 run [`32082049856`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32082049856) 和最新 Windows CI；仅修正文档事实，不改变代码行为。

验收标准：质量门禁失败时不创建 Release；三端包内版本均为 `v1.0.2`；全量 Flutter 测试可在固定时间内结束。

## M9 · 无签名环境的翻译体验

目标：不申请签名证书时，macOS 仍可完成第三方翻译功能。

本轮已完成：

- 设置页增加目标语言选择，默认中文，并持久化到普通设置。
- 文件、视频和实时字幕翻译都会使用已保存的目标语言。
- 设置页增加“测试 API 连接”，通过最小请求验证 endpoint、模型和 API Key；状态文本不显示 API Key，并隐藏 endpoint 中的 userinfo、query 和 fragment。
- 翻译前显示第三方数据发送提示，明确字幕文本会离开本机并发送到用户配置的服务商；文件、视频和实时字幕入口分别在首次使用前拦截确认。
- 实时翻译失败后可对单条字幕重试；重试只更新译文，不修改原文和时间轴，且实时翻译关闭时不会隐式发起请求。
- 设置页明确显示 API Key 使用系统安全存储还是当前会话存储。
- 已补充可选的真实第三方 OpenAI-compatible API 英/日视频验收入口：`app/integration_test/api_translation_acceptance_test.dart` 从仓库外 JSON 配置读取 endpoint、模型、API Key 和目标语言，输出双语 SRT 并验证视频叠加字幕；真实网络调用仍按个人使用范围不作为交付门禁。提交 `2381bee` 的 Windows CI run [`32086635129`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32086635129) 已通过。
- 2026-08-18 代码审查修复了该验收入口的播放跳转点：改用字幕段中点，避免跳到字幕结束之后；本地 mock OpenAI-compatible endpoint 已通过英/日视频转写、双语 SRT 和视频叠加字幕端到端回归，不替代真实第三方 API 网络验收。

待完成：

- 无。

验收标准：macOS 无签名包、Windows 和 Android 均能完成文件、实时、视频三条翻译路径；API Key 永不写入 Git、普通设置或日志。

## M10 · 真实设备与下载安全验收

目标：把模拟器和 CI 结果补成真实用户环境数据。

任务：

- Android 真机测量模型下载、麦克风实时识别、视频解码、内存和 RTF。
- Windows 用户桌面安装后验证首次启动、模型下载、麦克风、MP4 播放和字幕导出。
- 记录最低可接受配置和推荐线程数，必要时按设备降低实时识别负载。
- 在国内网络环境验证三源下载；全部失败时再评估增加 ModelScope 或自有对象存储源。

已完成的自动化补强：

- Windows CI 已安装带附加库的 `ffmpeg-full`，先检查 `ass/libass` 滤镜，再用真实 MP4 运行硬字幕编码 smoke；run `32048430484` 的 Flutter analyze、桌面 smoke、硬字幕 smoke、Release 构建和产物校验全部通过。
- 已提供 `app/integration_test/device_acceptance_test.dart` 和 [`M10_DEVICE_ACCEPTANCE.md`](M10_DEVICE_ACCEPTANCE.md)：可在 Android 真机或 Windows 桌面实际下载/校验模型，记录设备标识、实际语言/线程配置、模型目录占用、各阶段进程 RSS 当前值/峰值、文件 RTF、视频播放和可选真实麦克风实时 RTF；可选项未传入时会明确跳过，不伪造实机结果。提交 `cce0412` 的 Windows 回归 run `32052413073` 已通过。

验收标准：真机实时识别不会持续积压；Windows 安装包能在干净用户目录启动；模型校验失败会删除坏缓存并允许重试。

当前审计（2026-08-18）：

- Windows 最新提交已由 CI run `32048430484` 通过 Flutter analyze、Release 构建、桌面 smoke、`ass/libass` 检查、硬字幕编码 smoke、产物校验和 artifact 上传；完整模型 E2E 仍由 run `31919855391` 提供依据。
- 2026-08-18 手动触发最新 `main` 的 Windows 完整模型 E2E run `32075654714`：7 项测试全部通过，覆盖模型目录、WAV/m4a 解码、粤语 WAV/m4a 识别、真实 MP4 播放/跳转/抽音轨识别和三句实时识别；粤语 WAV RTF `0.055`，实时定稿 4 句、局部结果 4 条。同一 run 的桌面 smoke、硬字幕 smoke、Release 构建、运行时依赖、模型排除和 artifact 上传也通过；该结果仍不替代 Windows 用户桌面手工安装。
- 2026-08-18 推送 `ba07d04` 后的 Windows workflow run `32078081707` 增加并通过安装包 CI smoke：未签名安装包实际静默安装到空目录，验证四个运行时 DLL、模型排除，并在隔离 `APPDATA`/`LOCALAPPDATA` 下启动已安装程序保持运行 8 秒；该结果仍不替代用户桌面手工验收。
- 2026-08-18 推送修复提交 `bd64894` 后的 Windows workflow run [`32088850142`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32088850142) 通过 Flutter analyze、Release 构建、桌面 smoke、硬字幕 smoke、产物校验、安装包首次启动和 artifact 上传；完整模型 E2E 受 workflow 条件约束本次跳过，仍由手动 run `32075654714` 提供最新依据。
- M10 的统一报告入口和 Windows/Android 执行手册已提交；报告会保留设备系统、可选设备标识、实际语言/线程配置、模型准备耗时、模型目录占用、各阶段进程 RSS 当前值/峰值、文件 RTF、视频打开耗时和麦克风积压判定，但当前没有真实设备数据。
- 2026-08-18 已按当前工作树在 API 35 ARM64 模拟器复测统一入口：模型完整性通过，2 线程 `yue.wav` 文件 RTF `0.026807`，模型准备约 83.6 秒、模型目录约 241 MB，模型准备后 RSS 当前约 394 MiB、峰值约 429 MiB；此前同一入口已用 H.264+AAC MP4 通过音轨解码、播放器打开和播放推进（528 ms / 146 ms / 3.021 s），本次视频和麦克风参数未提供而明确跳过。该基线不替代真机数据，入口同时修复了首次慢速下载的 12 分钟超时边界并将下载日志按约 1 MiB 节流，详见 [`M10_DEVICE_ACCEPTANCE.md`](M10_DEVICE_ACCEPTANCE.md)。
- 2026-08-18 按当前工作树重新运行 API 35 ARM64 模拟器统一入口：JDK 17 构建成功，模型首次准备 84,782 ms、目录 241,150,289 bytes，完整性通过，2 线程 `yue.wav` 文件 RTF `0.026418`，解码/识别耗时 10/136 ms；模型准备后 RSS 当前 442,556,416 bytes，文件 worker 加载后峰值 758,063,104 bytes。视频和麦克风因未传入参数明确跳过；该数据不替代 Android 真机性能、内存、实时 RTF 或厂商 Codec 验收。
- 2026-08-18 已补充 API 35 ARM64 模拟器麦克风基线：先完成系统权限后再计时，5 秒请求实际采集 4.928 秒，会话耗时 5,031 ms，麦克风 RTF `1.020901`，未持续积压；模拟器没有人工讲话，产出段数为 0，因此只证明采样和实时管线基线，不替代 Android 真机语音质量/性能。验收入口同时修正了权限对话框等待时间被计入 RTF 的问题，详见 [`M10_DEVICE_ACCEPTANCE.md`](M10_DEVICE_ACCEPTANCE.md)。
- 2026-08-18 已补充 Android release APK 安装启动基线：API 35 ARM64 模拟器实际安装约 178.6 MB 的 `1.0.2 (999)` APK，v2 签名、模型排除和清除旧数据后的冷启动通过，进程稳定运行 8 秒；脚本为 `scripts/android_apk_install_smoke.sh`，该结果仍不替代 Android 真机性能/内存/RTF 和厂商 Codec 验收。
- 2026-08-18 已将 Android release APK 安装/冷启动 smoke 接入 `.github/workflows/release.yml`：发布资产校验后使用 API 35 `google_apis` x86_64 模拟器执行同一脚本，并将 Android job 限制为 30 分钟；手动 `v1.0.2` 发布 run [`32082049856`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32082049856) 已通过并将 Release 资产更新到提交 `5d64f49`，仍不替代 Android 真机验收。
- 2026-08-18 在当前 macOS 主机复测模型三源：对识别模型前 2 MiB 的分段请求均返回 HTTP `206`，GitHub / `ghfast.top` / `gh-proxy.com` 速度约为 360,833 / 437,475 / 317,526 B/s；这只证明当前主机可达，不替代国内 Windows 网络验收，三源 fallback 仍保留，详见 [`M10_DEVICE_ACCEPTANCE.md`](M10_DEVICE_ACCEPTANCE.md)。
- 本机没有可用 Android 真机或无线设备；API 35 ARM64 模拟器可用于功能验收，但 Android 真机性能、内存和 RTF 暂不能验收。
- 当前没有可操作的 Windows 用户桌面，干净用户目录安装、首次启动和真实桌面差异仍待实机验证。

## M11 · 项目保存与字幕导入（v1.1.0）

目标：关闭应用后仍能继续编辑、翻译和导出。

任务：

- 定义项目 JSON 格式，保存媒体路径、识别配置、分段、译文和编辑历史所需的当前快照。
- 增加“保存项目 / 打开项目 / 最近项目”。媒体文件只保存引用，不复制大视频。
- 编辑和翻译成功后自动保存，异常退出时提供恢复入口。
- 支持导入 SRT、VTT 和项目 JSON。
- 视频页可以直接加载外部字幕、编辑和翻译，无需重新识别视频。

验收标准：重新打开项目后字幕时间轴、译文和编辑结果一致；原媒体文件不存在时给出可恢复提示，不破坏项目文件。

当前进度：

- 已完成项目文件 v1 JSON schema、识别配置/分段/译文/时间轴校验、同目录临时文件保存，以及控制器快照恢复接口。
- 已接入首页“保存项目 / 打开项目”和“最近项目”；最近项目持久化最多 8 个路径，Android SAF 文件按字节读取并在应用支持目录保留稳定缓存。
- 已完成识别、字幕编辑、配置变更和翻译成功后的防抖自动保存；应用支持目录保留恢复快照，并用会话锁区分正常退出与异常退出，启动时可选择恢复或放弃。
- 已完成项目打开/恢复时的媒体存在性检查；媒体缺失时可继续编辑字幕或重新选择音频/视频，重新定位后的路径会进入当前快照，并刷新 Android 最近项目缓存。
- 已完成 SRT/VTT/JSON 字幕导入：SRT/VTT 会解析常见时间轴、清理基础标签并校验倒序/重叠；项目结果 JSON 会保留语言、时长、译文和 token 时间戳。
- 首页可直接导入带时间轴字幕；视频页可加载外部字幕并绑定当前视频，随后复用已有字幕编辑、第三方 API 翻译、播放叠加和导出链路；Android SAF 无本地路径时按字节读取。
- 相关解析、首页导入和视频外部字幕加载测试已覆盖，Flutter 全量测试为 234 项。

## M12 · 批量处理工作流（已完成）

目标：一次处理多个音频或视频文件，减少重复操作。

任务：

- [x] 多文件队列、暂停、取消、失败重试。
- [x] 每个文件独立显示解码、识别和翻译状态。
- [x] 批量翻译复用现有分批 provider，避免重复创建 HTTP client。
- [x] 按原文件名导出 SRT/VTT/JSON/TXT，并避免同批次文件名冲突；系统保存器对用户选择的既有文件显示覆盖确认。
- [x] 对已完成文本建立本地缓存，重复翻译前先确认是否复用。

验收标准：单个文件失败不阻塞队列；取消后不会继续写入译文或导出半成品；批量任务可恢复或明确报告失败项。

当前进度：

- 已完成多文件选择与去重、顺序转写、每文件状态和进度展示、暂停/继续、取消、失败重试；取消通过操作代次阻止迟到结果写回，也不会继续处理后续文件。
- 已完成批量翻译：批量页复用一次创建的 provider，逐文件复用现有分批/重试逻辑；每个文件独立显示翻译进度，单个文件失败不会阻塞后续文件，取消后迟到译文不会写回；翻译失败可单条重试。
- 已完成批量导出：支持 SRT/VTT/JSON/TXT，按原媒体文件名生成建议文件名，同批次重名自动追加序号；单个渲染/保存失败不阻塞其他文件，用户取消一个保存后停止后续导出。
- 已完成本地翻译缓存：缓存存放在应用私有支持目录，键包含媒体路径、未带译文的识别结果、目标语言、endpoint/model 配置和术语表；命中时先由用户选择复用、重新翻译或取消，缓存损坏、时间轴非法、源结果变化或缺少译文均按未命中处理，缓存写入失败不影响已成功翻译。
- 首页已接入“批量处理”页面；Android 多选若返回 SAF 字节而没有本地路径会明确提示，不静默加入不可处理的条目。
- 已完成批量任务持久化与恢复：队列变化防抖保存到应用私有目录，退出前强制保存；异常退出后可恢复或放弃任务，处理中/翻译中状态会降级为可继续状态，损坏条目和非法时间轴会被跳过。

## M13 · 可选增强（进行中）

当前优先实现字幕编辑器中低风险、可回滚的批处理能力：

- [x] 手工说话人标签：`Segment`/项目 JSON 支持可选标签；字幕校对可编辑、清空并在合并/拆分时正确传播；SRT/VTT/TXT 使用明确的 `[speaker:标签]` 标记，视频叠加和列表显示 `【标签】`。
- [x] 自动说话人分离：独立管理 pyannote segmentation 与 3D-Speaker embedding 模型，后台 isolate 调用 sherpa-onnx diarization API，按时间重叠把 `SPEAKER_00` 等标签写入字幕；首页支持自动估计人数或指定人数，标签可继续在校对页改名；新增单测和显式真实模型验收脚本，macOS 官方四人中文 WAV 真实模型验收通过，记录见 [`M13_DIARIZATION_ACCEPTANCE.md`](M13_DIARIZATION_ACCEPTANCE.md)。
- [x] 翻译术语表：设置页按每行 `原词=译词` 保存，所有第三方 API 翻译入口注入术语提示，批量缓存随术语表变化失效。
- [x] 服务商预设：设置页可保存、选择和删除常用 endpoint、模型、目标语言和术语表组合；预设不保存 API Key，损坏条目会被跳过。
- [x] 字幕批量时间偏移：同步移动字幕段和 token 时间戳，沿用时间轴边界校验，并支持撤销。
- [x] 字幕搜索替换：支持全局替换、大小写选项、空替换和撤销；文本变化会清除过期译文与 token 时间戳。
- [x] 阅读速度检查：按可配置的字符/秒阈值检查原文和译文中较长的一行，只报告超阈值字幕，不修改编辑结果。
- [x] 字幕样式：视频页支持字号、文字色、背景色和上/中/下位置，并持久化到普通设置。
- [x] 视频配套字幕导出：视频页按视频文件名导出 SRT/VTT/JSON/TXT；导出的是配套字幕文件，不重新编码视频。
- [x] 硬字幕视频编码：桌面调用本机 FFmpeg/ASS，Android 调用系统 MediaCodec + OpenGL + MediaMuxer，均生成带原文、译文、说话人标签并复用字幕样式的 MP4；Android 支持 AAC 音轨直通、系统可解码的非 AAC 音轨转 AAC，以及 SAF `content://` 输出（API 26+），新增 MethodChannel 单测、页面回归测试和跨平台真实验收脚本。AAC 与 MP3 音轨已在 API 35 ARM64 模拟器真实编码通过，Windows CI run `32056120388` 已通过 `ffmpeg-full`/`ass` 硬字幕 smoke，macOS `ffmpeg-full 9.0.1` 已通过 `app/tool/hard_subtitle_ffmpeg_acceptance_test.dart` 纯 VM 真实编码与重新解码；无开发证书的 Debug Runner 已使用 ad-hoc 签名完成集成启动与编码验收。普通 Homebrew FFmpeg 8.1.1 缺少 `libass` 时已通过负向验收，记录见 [`M13_FFMPEG_COMPATIBILITY.md`](M13_FFMPEG_COMPATIBILITY.md)；API 35 模拟器已补充通过 AV1+AAC 与 VP8+Vorbis，Android 真实设备、厂商 Codec 差异和 Windows 用户桌面仍待验收。
- [x] 文件转写性能诊断：记录模型准备、解码、识别和总耗时、RTF、采样点、模型占用、平台与 ASR/VAD 配置，并支持查看/导出 JSON。
- [x] 批量与实时识别性能汇总：批量页汇总文件数、成功/失败/取消、音频时长、累计解码/识别耗时和 RTF；实时页汇总采样点、音频时长、会话耗时和 RTF，并支持查看/导出 JSON。
- [x] 持续性能日志：将文件、批量和实时报告以版本化 JSON 持久化到应用私有目录，最多保留 100 条，支持查看、清空，并跳过损坏条目。

当前进度：M13 自动说话人分离和桌面/Android 硬字幕编码代码已完成代码审查、相关测试和验收脚本；本机 macOS 已用官方四人中文 WAV 和真实分离模型通过 Debug 集成验收，模型完整性、16 kHz 解码和输出时间段契约均通过，记录见 [`M13_DIARIZATION_ACCEPTANCE.md`](M13_DIARIZATION_ACCEPTANCE.md)。`flutter analyze`、Flutter 相关测试、Android Kotlin 编译和 Android API 35 ARM64 模拟器硬字幕真实编码均已通过，模拟器已分别验收 H.264+AAC、H.264+MP3、VP9+Opus、HEVC+AAC、AV1+AAC 和 VP8+Vorbis；Windows CI run `32060800502` 已用带 `libass` 的 `ffmpeg-full` 通过硬字幕编码 smoke；本机 macOS `ffmpeg-full 9.0.1` 已通过纯 VM 真实编码、重新解码以及无开发证书 ad-hoc Debug Runner 集成验收，普通 Homebrew FFmpeg 8.1.1 缺少 `libass` 时也已通过预期失败验收，记录见 [`M13_FFMPEG_COMPATIBILITY.md`](M13_FFMPEG_COMPATIBILITY.md)。Android 真机、厂商 Codec 差异和 Windows 用户桌面仍待具备环境后验收。下一步是完成真实设备验收，并根据设备结果补充兼容性。

补充验收：API 35 ARM64 模拟器已用多输入入口通过 H.264+AAC、H.264+MP3、VP9+Opus、HEVC+AAC、AV1+AAC、VP8+Vorbis 六种输入，记录见 [`M13_CODEC_ACCEPTANCE.md`](M13_CODEC_ACCEPTANCE.md)；该结果不替代 Android 真机和厂商 Codec 验收。

## 推荐执行顺序

```text
M8 发布质量基线
  ↓
M9 无签名翻译体验
  ↓
M10 Android 真机 / Windows 用户桌面验收
  ↓
M11 项目保存与字幕导入
  ↓
M12 批量处理与批量翻译
  ↓
M13 可选增强
```

每个阶段按“实现 → 代码审查 → 相关测试 → 文档同步 → 提交推送 → 必要时发布”完成，不把真实 API Key、签名证书或模型文件提交到仓库。
