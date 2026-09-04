# M20 真实设备兼容性验收记录

本阶段用于补齐 CI、模拟器和开发机之外的真实运行数据。验收入口为
[`app/integration_test/device_acceptance_test.dart`](app/integration_test/device_acceptance_test.dart)，普通
`flutter test` 不会自动执行这些设备测试。

## 当前状态（2026-09-04）

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| macOS Apple Silicon | 部分完成 | 长视频连续音轨解码、播放器打开/推进、三个播放列表条目切换，以及生命周期暂停时保存检查点、唤醒后继续的协调器回归已通过；真实睡眠唤醒和辅助功能语义树仍需手工验收 |
| Android 真机 | 待设备 | 当前开发机没有可用 Android 真机；API 35 模拟器结果不能替代真机 |
| Windows 用户桌面 | 待设备 | 当前开发机没有 Windows 用户桌面；CI 安装包 smoke 不能替代用户环境 |

M20 尚未完成，不能据此宣称三平台真实设备兼容性已经验收通过。

2026-09-04 已完成待验收的实现更新：文件/批量/实时转写改为按调度容量复用识别 worker 池，Android 硬字幕编码改为
前台服务并复用字幕位图，ONNX provider 可选 `auto`、`cpu`、`nnapi` 或 `coreml`。这组改动已通过
`flutter analyze` 和 269 项 Flutter 单测；当前开发机未安装 Java Runtime，尚未完成 Android Kotlin 编译。它们没有
在真实设备验证，不能作为 M20 的性能、内存或兼容性结论。

## macOS 自动化结果

2026-08-27 在 macOS `26.5.2 (Build 25F84)` Apple Silicon 上执行了 1 小时、约 400 MiB 的
H.264 + AAC 合成压力视频，并额外切换三个 8 秒 MP4 播放列表条目。媒体由 `ffmpeg` 的测试图像和正弦音频生成，
用于解码/播放压力测试，不代表真实语音识别质量。

报告摘要：

- 模型完整性校验通过；模型目录占用 `288,310,862` bytes。
- 设备资源记录为 `arm64`、10 个逻辑处理器、32 GiB 物理内存；本次实际使用 2 个识别线程，作为当前机器的推荐线程基线。
- 1 小时视频大小 `419,746,119` bytes，读取时长 `3600.083` 秒。
- 连续音轨解码读取 `57,599,632` samples，耗时约 `2,208` ms。
- 播放器打开耗时 `537` ms，并成功推进播放位置。
- 三个播放列表条目均成功打开，读取时长均为 `8.021` 秒，打开耗时 `151` ms / `113` ms / `113` ms。
- 连续解码后进程 RSS 约 `741` MB（约 `707` MiB）；播放器打开后约 `806` MB（约 `769` MiB）。测试已改为分块读取音轨，避免把整小时音频一次性放入 Dart `Float32List`。
- 播放器 widget 语义回归通过：字幕显示模式、当前倍速、当前位置、可调播放进度均有稳定标签；播放进度的辅助功能增减操作按 10 秒步进。
- 播放列表协调器回归通过：应用进入 `hidden`、`paused` 或 `detached` 时停止继续读取音频并保存当前检查点，恢复到 `resumed` 后重新排队；首个 30 秒检查点之前的短片段也会持久化，避免暂停时丢失进度。

另用可选的生产视频流式转写入口对一个 8.021 秒 H.264 + AAC MP4 做了管线 smoke：

- `TranscribeController.transcribeVideoStream` 成功完成，解码和识别分别耗时 `17` ms / `28` ms，读取并处理 `127,994` samples，1 个分块，结果时长 `7.999625` 秒。
- 该合成音频没有可识别语音，因此结果为 0 段字幕；这次只证明生产控制器、连续解码、worker 收尾和 `VideoTranscriptionReport` 写入链路可运行，不代表真实语音识别质量或长视频稳定性。
- 测试期间报告的流式转写峰值 RSS 为 `858,324,992` bytes；该数值受同一进程前序模型、文件识别和播放器测试影响，只作为本次 smoke 记录。

上述物理内存和 RSS 仅是当前 macOS 机器的资源基线，不能直接推导应用的最低可用内存；最低配置仍需在
内存受限的真实 Android/Windows 设备上通过长视频和持续转写压测确定。

复现命令（从仓库根目录执行；路径按本机媒体调整）：

```bash
cd app
VSASR_DEVICE_TEST_VIDEO=/path/to/long-video.mp4 \
VSASR_DEVICE_TEST_PLAYLIST='/path/to/one.mp4|/path/to/two.mp4|/path/to/three.mp4' \
VSASR_DEVICE_TEST_VIDEO_TRANSCRIPTION=1 \
VSASR_DEVICE_TEST_REPORT=/tmp/vsasr-m20-macos-report.json \
VSASR_DEVICE_LABEL=macOS-Apple-Silicon \
flutter test integration_test/device_acceptance_test.dart -d macos
```

`VSASR_DEVICE_TEST_PLAYLIST` 使用 `|` 分隔，至少需要两个存在的文件；不设置时仍只验收
`VSASR_DEVICE_TEST_VIDEO`，保持原有入口行为。报告会增加 `video_playlist.opened_items`，记录每个条目的
打开耗时和读取时长，并在 `device` 节点记录架构、逻辑处理器、可读取的物理内存和推荐线程数。
设置 `VSASR_DEVICE_TEST_VIDEO_TRANSCRIPTION=1` 后，会使用同一个视频（或播放列表首项）执行生产视频流式转写，
并在报告中增加 `video_transcription` 诊断节点；未设置时该测试明确跳过。短视频 smoke 不能替代真实含语音的长视频验收。

## 尚未完成的手工清单

### macOS

- 播放长视频转写期间让系统真实睡眠并唤醒，确认平台事件能触发上述暂停/恢复路径，任务不会卡死、重复写入或丢失检查点；当前只有 Flutter 协调器回归，尚未完成真实系统手工操作。
- 在 macOS 辅助功能检查器中确认播放按钮、字幕显示模式、原文/译文选择、倍速、左右键快进和播放列表条目在真实系统语义树中有稳定名称；当前仅完成 Flutter 语义 widget 回归，尚未完成检查器手工确认。
- 使用真实含语音的长视频复测字幕持续生成、翻译和缓存恢复；合成压力视频只覆盖音轨解码与播放器生命周期。

### Android 真机

连接启用 USB 调试的设备后，从 `app/` 执行：

```bash
flutter test integration_test/device_acceptance_test.dart -d <android-device-id> \
  --dart-define=VSASR_DEVICE_LABEL=<model-and-android-version> \
  --dart-define=VSASR_DEVICE_TEST_MIC_SECONDS=15 \
  --dart-define=VSASR_DEVICE_TEST_VIDEO=/path/in/device-storage/input.mp4
```

需保存模型下载/校验、文件 RTF、麦克风 RTF、RSS、视频播放和硬字幕编码结果，并注明厂商、芯片、
Android 版本、输入格式和是否出现持续积压。硬字幕编码还需确认前台通知在长任务期间可见且任务不会被系统回收；
设备支持时分别记录 `nnapi` 与 `cpu` provider 的结果和错误信息。

### Windows 用户桌面

从 GitHub Release 下载未签名安装包，在干净用户目录安装并按
[`M10_DEVICE_ACCEPTANCE.md`](M10_DEVICE_ACCEPTANCE.md) 的清单验证首次启动、模型下载、麦克风、长 MP4、
字幕导出、重启恢复和 API Key 隔离。随后可在安装目录对应的源码环境运行 device acceptance，报告需与安装包手工结果分开保存。

## 判定与下一步

本次 macOS 自动化结果证明分块解码、三个播放列表条目切换和生命周期暂停/恢复代码路径在当前开发机上可运行，但不移除 M20 的 Android 真机、Windows
用户桌面、macOS 睡眠唤醒和辅助功能待验收项。下一步应先获取两类真实设备，再按平台分别补齐报告；若发现问题，记录设备、输入格式、
复现步骤、日志和报告路径。macOS 设备还应在支持时记录 `coreml` provider 的结果，并与 `cpu` 结果分开保存。
