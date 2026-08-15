# VoiceSmallASR 开发记忆

> 更新时间：2026-08-16

## 当前阶段

- Python 端已完成：离线多语种识别、CLI、VAD 流式识别、时间戳和字幕导出。
- Flutter 端已完成 M1（文件转写 + 字幕导出）和 M2（麦克风实时字幕）的 macOS 闭环。
- 当前下一阶段是 M3：视频播放、字幕叠加、播放进度与字幕联动。

## 已验证结果

- Python：`pytest` 105 项通过，`ruff check .` 通过。
- Flutter：`flutter analyze` 通过，103 项单测通过。
- macOS：`flutter build macos --debug` 通过，Swift 原生音频解码已编译。
- macOS 真模型端到端验收已完成：Flutter 与 Python 对粤语素材逐字一致，实时识别链路的定稿序号和时间戳连续。

## 最近修复

- 同步 `record 7.1.1` 的 `hasPermission({bool request})` 测试替身签名。
- Flutter 模型下载的连接和响应流增加 60 秒超时，超时后切换镜像源。
- 实时会话收尾时用 `finally` 释放 VAD 原生资源。
- Windows Media Foundation 解码线程增加异常和线程创建失败兜底，确保 MethodChannel 回包。

## 尚未验证的环境

- Android 原生 Kotlin 解码尚未在 Android SDK/真机上编译运行。
- Windows 原生 C++ 解码尚未在 MSVC/Windows SDK 上编译运行。
- Android 实时字幕的中低端设备性能尚未测量。

## 工作约定

每个开发计划项按“实现 → 代码审查 → 修复 → 相关测试 → 更新本文件和 `DEVELOPMENT_PLAN.md` → 提交推送”推进。
