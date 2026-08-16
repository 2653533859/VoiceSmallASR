# VoiceSmallASR 开发记忆

> 更新时间：2026-08-16

## 当前阶段

- Python 端已完成：离线多语种识别、CLI、VAD 流式识别、时间戳和字幕导出。
- Flutter 端已完成 M1（文件转写 + 字幕导出）和 M2（麦克风实时字幕）的 macOS 闭环。
- M3 已完成：跨平台视频播放器、字幕叠加、播放进度联动与点击字幕跳转，真实英文 `en.mp4` 已在 macOS 端到端验收。
- M4 的第一项已完成：加入服务商无关的 `TranslationProvider` 和 `translateResult()`，可在校验返回数量后把译文安全写入 `Segment.translation`。
- M4 的批量流程已完成：`translateResult()` 支持分批、失败重试、延迟和累计进度回报，全部批次成功后才写回译文。
- M4 的双语字幕导出已完成：SRT/VTT/TXT 输出原文与译文双行，JSON 保留结构化译文；带译文的长段不切分以保持时间边界一致。
- M4 的首期在线 provider 已完成：`DeepLTranslationProvider` 使用官方 v2 接口，支持 API 错误脱敏、自动/显式源语言和 128 KiB 请求体拆分。
- M4 的应用内翻译工作流已完成：文件转写页从安全存储读取 DeepL API Key，显示批量进度，成功后回写译文，失败时保留原结果；译文会显示在列表并进入后续导出/视频叠加链路。
- M6 首期设置页与模型管理已完成：语言、线程数、ITN、临时结果间隔、VAD 断句参数和 DeepL API Key 可保存；普通设置/离线模式用 `shared_preferences`，API Key 用 `flutter_secure_storage`，启动时恢复配置；设置页支持模型下载、删除与占用空间显示。
- M5 首期字幕校对编辑已完成：支持文本/时间编辑、合并/拆分、撤销/重做、播放器定位和保存回写；导出前会拒绝重叠、倒序或超出音频时长的时间轴。
- M7 macOS 无签名打包首期已完成：`scripts/build_macos_unsigned.sh` 可生成通用 arm64/x86_64 `.app` 与 UDZO `.dmg`，构建产物不含模型；带证书的签名发布仍待配置。
- M7 Android 构建验证已完成：本机 Android SDK 36 / Build-Tools 36.1.0 / NDK 28.2.13676358 + JDK 17 成功生成 release APK 和 AAB；APK/AAB 不含模型，release 使用 debug signing，仅代表可构建。
- Android 模拟器功能验收已完成：API 35 ARM64 `vsasr-api35` 通过 7 项真实端到端测试，覆盖 Kotlin 原生 m4a 解码、模型识别、media_kit 视频播放/跳转/抽音轨和实时识别；2026-08-16 重跑 7/7，粤语识别 RTF `0.027`；模拟器使用软件渲染，真机性能仍未验证。
- M4 真实验收入口已准备：`scripts/prepare_translation_acceptance_media.sh` 生成英/日视频素材，`app/integration_test/deepl_acceptance_test.dart` 使用仓库外的 `--dart-define-from-file` 密钥文件验证真实 DeepL、双语 SRT 和视频字幕叠加；本机尚无有效 DeepL API Key，因此尚未执行网络验收。
- Windows M7 构建已完成：GitHub Actions run `31912544699` 在 `windows-2022` runner 上通过 MSVC 编译 Flutter Release，并用 `scripts/build_windows_unsigned.ps1` + Inno Setup 生成未签名安装包；CI 自动检查 `vsasr_app.exe`、安装包和四个运行时 DLL，并拒绝模型文件；Release 目录约 111 MiB，安装包约 31 MiB。
- Windows 完整模型 e2e 入口已补齐：`.github/workflows/windows-build.yml` 的手动 `run_full_e2e=true` 会恢复模型缓存，必要时通过三源 fallback 下载并做最小字节数校验，再用 `VSASR_MODEL_DIR` 指向外部模型目录运行 `integration_test/e2e_test.dart`；实际 Windows runner 验收仍待执行。
- 当前下一步是触发 Windows 完整模型 e2e，并用真实网络完成英/日视频翻译验收；此外仍需补 Android 真机性能、Windows 用户桌面运行验证，并继续推进签名发布。

## 已验证结果

- Python：`pytest` 105 项通过，`ruff check .` 通过。
- Flutter：`flutter analyze` 通过，149 项单测通过。
- macOS：无签名模式的 `xcodebuild` 已成功编译并打包（含 secure storage plugin）；普通 `flutter build macos --debug` 因本机没有开发证书而无法完成签名。
- M7 打包：已生成 `dist/macos/VoiceSmallASR.app`（通用二进制，约 161 MB）和 `VoiceSmallASR-unsigned.dmg`（约 64 MB），并用 `hdiutil imageinfo` 验证为 UDZO 镜像。
- Android M7 构建：`app/build/app/outputs/flutter-apk/app-release.apk`（169 MiB，177,219,459 bytes）和 `app/build/app/outputs/bundle/release/app-release.aab`（124 MiB，129,974,495 bytes）构建成功；APK 含 arm64-v8a、armeabi-v7a、x86_64，`apksigner verify --verbose` 通过 v2 签名校验，APK/AAB 均未打入 `.onnx`、tar 或 `tokens.txt` 模型文件。
- Windows M7 构建：run `31912544699` 的 `vsasr_app.exe`（141,312 bytes）和 `VoiceSmallASR-unsigned-setup.exe`（32,809,700 bytes）均为 x86-64 PE 文件；Release 目录约 111 MiB，包含 sherpa/ONNX、media_kit 原生 DLL，CI 自动确认未打入 `.onnx`、`.tar`、`.bz2` 或 `tokens.txt` 模型文件。
- Windows 桌面 smoke：run `31914757787` 的 2 项测试通过，验证 Media Foundation AAC 解码，以及 media_kit MP4 打开、读取时长和播放；该 smoke 不加载 ASR 模型。
- Android API 35 模拟器 e2e：2026-08-16 重跑 7 项全部通过，真实模型识别结果与 Python 基线一致，RTF `0.027`；该结果仅作为模拟器基线，不代表真机性能。
- 播放器：`media_kit 1.2.6` + `media_kit_video 2.0.1` + `media_kit_libs_video 1.0.7` 已接入；macOS 无签名编译通过，插件当前由 CocoaPods 集成。
- M3 测试覆盖：播放器状态/生命周期、字幕时间边界、视频页加载/叠加/点击跳转；7 项集成测试包含真实 `en.mp4` 播放、跳转、抽音轨和识别。
- M4 测试覆盖：6 项翻译抽象/批量流程测试、4 项双语导出测试、6 项 DeepL provider 测试。
- 双语字幕导出测试：4 项，覆盖 SRT/VTT/TXT/JSON、译文顺序、关闭双语和长段时间边界。
- M6 测试覆盖：3 项 API Key 安全存储测试、4 项普通设置/离线模式持久化测试、2 项设置页测试、1 项配置变更后 worker 重启测试，以及 4 项模型/worker 生命周期测试。
- M5 测试覆盖：9 项字幕编辑器、页面交互和导出时间轴校验测试。
- M4 翻译工作流新增 4 项状态机/页面测试；真实 DeepL 网络验收仍未执行。
- macOS 真模型端到端验收已完成：Flutter 与 Python 对粤语素材逐字一致，实时识别链路的定稿序号和时间戳连续。

## 最近修复

- 同步 `record 7.1.1` 的 `hasPermission({bool request})` 测试替身签名。
- Flutter 模型下载的连接和响应流增加 60 秒超时，超时后切换镜像源。
- 实时会话收尾时用 `finally` 释放 VAD 原生资源。
- Windows Media Foundation 解码线程增加异常和线程创建失败兜底，确保 MethodChannel 回包。
- 播放器异步操作在页面销毁后不再访问已销毁的状态对象；无扩展名路径判断视频时不再越界。
- `media_kit` 集成测试先挂载真实 `Video` 完成首帧初始化，再调用播放器 `open()`；英文素材按首个有效字幕段验证，避免假设整段只有一个 cue。
- Windows 完整 e2e 模型准备改为多源下载、每源有限重试、最低 256 KiB/s 低速超时、最小文件大小校验和 Actions cache；`VSASR_MODEL_DIR` 仅在显式设置时覆盖默认应用私有模型目录。

## 尚未验证的环境

- Android 原生 Kotlin 解码已在 API 35 ARM64 模拟器端到端运行验证，但尚未在真机运行。
- Windows 原生 C++ 解码已在 MSVC/Windows SDK 上编译，并在 CI 桌面 smoke 中通过 AAC 解码；完整模型 e2e 与用户桌面运行仍未验证。
- Android 模拟器的 media_kit 视频播放已通过端到端验证；Windows CI smoke 已通过 media_kit MP4 打开、读取时长和播放，用户桌面差异仍未验证。
- Android 实时字幕的中低端设备性能尚未测量。

## 工作约定

每个开发计划项按“实现 → 代码审查 → 修复 → 相关测试 → 更新本文件和 `DEVELOPMENT_PLAN.md` → 提交推送”推进。
