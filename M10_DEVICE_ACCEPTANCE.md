# M10 真机与用户桌面验收手册

这份手册用于补齐模拟器/CI 之外的真实环境数据。验收入口是
`app/integration_test/device_acceptance_test.dart`，它不会进入普通
`flutter test`，必须在目标 Android 真机或 Windows 桌面显式运行。

## 自动化报告覆盖范围

测试会执行并写出 `device_acceptance_report.json`：

- 模型：缺失时实际下载，随后执行固定 SHA-256 完整性校验，并记录下载/准备耗时和模型目录占用。
- 内存：通过 `dart:io ProcessInfo` 记录模型准备、文件识别、视频播放和麦克风会话各阶段的当前 RSS，以及进程峰值 RSS；不支持该 API 时记录为 `null`。
- 文件转写：默认使用模型包内的 `test_wavs/yue.wav`，记录原生解码耗时、识别耗时和文件 RTF。
- 视频：设置 `VSASR_DEVICE_TEST_VIDEO` 后，记录视频音轨解码、播放器打开耗时和真实播放推进。
- 麦克风：设置 `VSASR_DEVICE_TEST_MIC_SECONDS` 后，真实申请权限并采集麦克风，记录采样时长、实时 RTF 和是否持续积压。

默认实时验收阈值是 RTF `<= 1.25`。如果设备需要调整线程或 VAD 参数，可设置
`VSASR_DEVICE_THREADS`、`VSASR_DEVICE_LANGUAGE` 和
`VSASR_DEVICE_MAX_LIVE_RTF`，但报告中必须保留实际配置和理由。

## Android 真机

准备：打开 USB 调试，确认设备可见；首次运行允许网络和麦克风权限。

```bash
cd app
flutter devices

# 默认下载模型并使用模型包内的 yue.wav；录音 15 秒。
flutter test integration_test/device_acceptance_test.dart -d <android-device-id> \
  --dart-define=VSASR_DEVICE_TEST_MIC_SECONDS=15
```

Android 集成测试不可靠地继承 shell 环境变量，因此路径和开关优先使用
`--dart-define`。如果有应用可读的本地 MP4，可额外传入：

```bash
flutter test integration_test/device_acceptance_test.dart -d <android-device-id> \
  --dart-define=VSASR_DEVICE_TEST_MIC_SECONDS=15 \
  --dart-define=VSASR_DEVICE_TEST_VIDEO=/path/in/app-readable-storage/input.mp4
```

测试日志会打印报告位置和 JSON 内容；不指定报告路径时，报告写入应用模型目录。
至少应保存以下信息：设备型号、Android 版本、线程数、模型准备耗时、模型目录占用、进程 RSS
当前值/峰值、文件 RTF、麦克风 RTF 和是否出现持续积压。若只运行模拟器，必须在记录中标注“非真机结果”。

## Windows 用户桌面

自动化性能测试需要 Flutter/Visual Studio 开发环境，运行的是同一份桌面代码；它不能替代
安装包本身的手工验收。先从 [GitHub Release v1.0.2](https://github.com/2653533859/VoiceSmallASR/releases/tag/v1.0.2)
下载未签名安装包，在全新的 Windows 用户目录安装，然后逐项确认：

- 首次启动不弹缺少 DLL、模型或权限错误；
- 设置页可以下载模型，下载中断后重试能继续完成，模型校验失败后不会复用坏缓存；
- 文件转写页可以选择麦克风/音频文件并完成识别；
- 实时字幕页可以获得麦克风权限并持续说话，字幕不会持续落后；
- 视频页可以打开 MP4、播放/跳转、翻译字幕并导出配套字幕或硬字幕 MP4；
- 退出后重新启动，设置和已保存项目仍可读取，API Key 不出现在普通配置和日志中。

若需要量化数据，在源码目录的 `app/` 中运行：

```powershell
$env:VSASR_DEVICE_TEST_MIC_SECONDS = "15"
$env:VSASR_DEVICE_TEST_VIDEO = "C:\path\to\acceptance.mp4"
$env:VSASR_DEVICE_TEST_REPORT = "$env:LOCALAPPDATA\VoiceSmallASR\device_acceptance_report.json"
flutter test integration_test/device_acceptance_test.dart -d windows
```

最终记录应区分“安装包手工结果”和“源码集成测试报告”，不能只用 Windows CI 的结果代替。

## 结果判定

自动化报告满足以下条件后，才可把对应子项从 M10 的待验收列表移除：

1. `model.verified` 为 `true`，且模型准备过程没有复用截断或校验错误的缓存。
2. 文件转写有有效音频时长和 RTF；模型准备耗时、模型目录占用、进程 RSS 和线程数已记录。RSS 是进程驻留集大小，用于同一设备上的阶段对比，不等同于模型精确分配量。
3. Windows 用户桌面手工清单全部完成；Android 真机至少完成模型、麦克风和实时 RTF 记录。
4. 视频项不跳过时，报告包含真实 MP4 的音轨解码和播放器推进结果。

当前仓库已提供入口和报告格式，但本机仍没有 Android 真机或可操作的 Windows 用户桌面，
因此 M10 的真实环境状态仍保持“待实机验收”。
