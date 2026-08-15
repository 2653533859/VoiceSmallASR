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
- M6 首期设置页与模型管理已完成：语言、线程数、ITN、临时结果间隔、VAD 断句参数和 DeepL API Key 可保存；普通设置/离线模式用 `shared_preferences`，API Key 用 `flutter_secure_storage`，启动时恢复配置；设置页支持模型下载、删除与占用空间显示。
- M5 首期字幕校对编辑已完成：支持文本/时间编辑、合并/拆分、撤销/重做、播放器定位和保存回写；导出前会拒绝重叠、倒序或超出音频时长的时间轴。
- 当前下一步是用真实网络完成英/日视频翻译验收，补 Android/Windows 的构建与运行验证，并推进 M7 打包分发。

## 已验证结果

- Python：`pytest` 105 项通过，`ruff check .` 通过。
- Flutter：`flutter analyze` 通过，145 项单测通过。
- macOS：无签名模式的 `xcodebuild` 已成功编译并打包（含 secure storage plugin）；普通 `flutter build macos --debug` 因本机没有开发证书而无法完成签名。
- 播放器：`media_kit 1.2.6` + `media_kit_video 2.0.1` + `media_kit_libs_video 1.0.7` 已接入；macOS 无签名编译通过，插件当前由 CocoaPods 集成。
- M3 测试覆盖：播放器状态/生命周期、字幕时间边界、视频页加载/叠加/点击跳转；7 项集成测试包含真实 `en.mp4` 播放、跳转、抽音轨和识别。
- M4 测试覆盖：6 项翻译抽象/批量流程测试、4 项双语导出测试、6 项 DeepL provider 测试。
- 双语字幕导出测试：4 项，覆盖 SRT/VTT/TXT/JSON、译文顺序、关闭双语和长段时间边界。
- M6 测试覆盖：3 项 API Key 安全存储测试、4 项普通设置/离线模式持久化测试、2 项设置页测试、1 项配置变更后 worker 重启测试，以及 4 项模型/worker 生命周期测试。
- M5 测试覆盖：9 项字幕编辑器、页面交互和导出时间轴校验测试。
- macOS 真模型端到端验收已完成：Flutter 与 Python 对粤语素材逐字一致，实时识别链路的定稿序号和时间戳连续。

## 最近修复

- 同步 `record 7.1.1` 的 `hasPermission({bool request})` 测试替身签名。
- Flutter 模型下载的连接和响应流增加 60 秒超时，超时后切换镜像源。
- 实时会话收尾时用 `finally` 释放 VAD 原生资源。
- Windows Media Foundation 解码线程增加异常和线程创建失败兜底，确保 MethodChannel 回包。
- 播放器异步操作在页面销毁后不再访问已销毁的状态对象；无扩展名路径判断视频时不再越界。
- `media_kit` 集成测试先挂载真实 `Video` 完成首帧初始化，再调用播放器 `open()`；英文素材按首个有效字幕段验证，避免假设整段只有一个 cue。

## 尚未验证的环境

- Android 原生 Kotlin 解码尚未在 Android SDK/真机上编译运行。
- Windows 原生 C++ 解码尚未在 MSVC/Windows SDK 上编译运行。
- Android/Windows 的 media_kit 视频播放尚未在真机/真桌面运行验证。
- Android 实时字幕的中低端设备性能尚未测量。

## 工作约定

每个开发计划项按“实现 → 代码审查 → 修复 → 相关测试 → 更新本文件和 `DEVELOPMENT_PLAN.md` → 提交推送”推进。
