# M20 真实设备兼容性验收记录

本阶段用于补齐 CI、模拟器和开发机之外的真实运行数据。验收入口为
[`app/integration_test/device_acceptance_test.dart`](app/integration_test/device_acceptance_test.dart)，普通
`flutter test` 不会自动执行这些设备测试。

## 当前状态（2026-08-27）

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| macOS Apple Silicon | 部分完成 | 长视频连续音轨解码、播放器打开/推进、两个播放列表条目切换已通过；睡眠唤醒和辅助功能语义树仍需手工验收 |
| Android 真机 | 待设备 | 当前开发机没有可用 Android 真机；API 35 模拟器结果不能替代真机 |
| Windows 用户桌面 | 待设备 | 当前开发机没有 Windows 用户桌面；CI 安装包 smoke 不能替代用户环境 |

M20 尚未完成，不能据此宣称三平台真实设备兼容性已经验收通过。

## macOS 自动化结果

2026-08-27 在 macOS `26.5.2 (Build 25F84)` Apple Silicon 上执行了 1 小时、约 400 MiB 的
H.264 + AAC 合成压力视频，并额外切换两个 8 秒 MP4 播放列表条目。媒体由 `ffmpeg` 的测试图像和正弦音频生成，
用于解码/播放压力测试，不代表真实语音识别质量。

报告摘要：

- 模型完整性校验通过；模型目录占用 `288,310,862` bytes。
- 1 小时视频大小 `419,746,119` bytes，读取时长 `3600.083` 秒。
- 连续音轨解码读取 `57,599,632` samples，耗时约 `2,190` ms。
- 播放器打开耗时 `532` ms，并成功推进播放位置。
- 两个播放列表条目均成功打开，读取时长均为 `8.021` 秒，打开耗时 `152` ms / `112` ms。
- 连续解码后进程 RSS 约 `775` MiB；播放器打开后约 `850` MiB。测试已改为分块读取音轨，避免把整小时音频一次性放入 Dart `Float32List`。

复现命令（从仓库根目录执行；路径按本机媒体调整）：

```bash
cd app
VSASR_DEVICE_TEST_VIDEO=/path/to/long-video.mp4 \
VSASR_DEVICE_TEST_PLAYLIST='/path/to/one.mp4|/path/to/two.mp4' \
VSASR_DEVICE_TEST_REPORT=/tmp/vsasr-m20-macos-report.json \
VSASR_DEVICE_LABEL=macOS-Apple-Silicon \
flutter test integration_test/device_acceptance_test.dart -d macos
```

`VSASR_DEVICE_TEST_PLAYLIST` 使用 `|` 分隔，至少需要两个存在的文件；不设置时仍只验收
`VSASR_DEVICE_TEST_VIDEO`，保持原有入口行为。报告会增加 `video_playlist.opened_items`，记录每个条目的
打开耗时和读取时长。

## 尚未完成的手工清单

### macOS

- 播放长视频转写期间让系统睡眠并唤醒，确认任务不会卡死、重复写入或丢失检查点。
- 在 macOS 辅助功能检查器中确认播放按钮、字幕显示模式、原文/译文选择、倍速、左右键快进和播放列表条目有稳定语义名称。
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
Android 版本、输入格式和是否出现持续积压。

### Windows 用户桌面

从 GitHub Release 下载未签名安装包，在干净用户目录安装并按
[`M10_DEVICE_ACCEPTANCE.md`](M10_DEVICE_ACCEPTANCE.md) 的清单验证首次启动、模型下载、麦克风、长 MP4、
字幕导出、重启恢复和 API Key 隔离。随后可在安装目录对应的源码环境运行 device acceptance，报告需与安装包手工结果分开保存。

## 判定与下一步

本次 macOS 自动化结果证明分块解码和播放列表切换在当前开发机上可运行，但不移除 M20 的 Android 真机、Windows
用户桌面、macOS 睡眠唤醒和辅助功能待验收项。下一步应先获取两类真实设备，再按平台分别补齐报告；若发现问题，记录设备、输入格式、
复现步骤、日志和报告路径。
