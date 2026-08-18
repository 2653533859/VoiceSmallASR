# M10 真机与用户桌面验收手册

这份手册用于补齐模拟器/CI 之外的真实环境数据。验收入口是
`app/integration_test/device_acceptance_test.dart`，它不会进入普通
`flutter test`，必须在目标 Android 真机或 Windows 桌面显式运行。

## 自动化报告覆盖范围

测试会执行并写出 `device_acceptance_report.json`：

- 模型：缺失时实际下载，随后执行固定 SHA-256 完整性校验，并记录下载/准备耗时和模型目录占用。
- 环境与配置：记录平台、系统版本、可选的 `device_label`、语言、实际线程数，以及麦克风验收时使用的时长和 RTF 阈值。
- 内存：通过 `dart:io ProcessInfo` 记录模型准备、文件识别、视频播放和麦克风会话各阶段的当前 RSS，以及进程峰值 RSS；不支持该 API 时记录为 `null`。
- 文件转写：默认使用模型包内的 `test_wavs/yue.wav`，记录原生解码耗时、识别耗时和文件 RTF。
- 视频：设置 `VSASR_DEVICE_TEST_VIDEO` 后，记录视频音轨解码、播放器打开耗时和真实播放推进。
- 麦克风：设置 `VSASR_DEVICE_TEST_MIC_SECONDS` 后，真实申请权限并采集麦克风，记录采样时长、实时 RTF 和是否持续积压。

默认实时验收阈值是 RTF `<= 1.25`。如果设备需要调整线程或 VAD 参数，可设置
`VSASR_DEVICE_THREADS`、`VSASR_DEVICE_LANGUAGE` 和
`VSASR_DEVICE_MAX_LIVE_RTF`，但报告中必须保留实际配置和理由。

验收入口的首次模型准备设置了 30 分钟库级超时，以覆盖慢速镜像的完整下载；下载进度按
约 1 MiB 或阶段变化输出，避免每个网络 chunk 都刷屏。该超时和日志策略只用于显式设备验收，
不影响普通 `flutter test`。

## 模型下载三源复测（当前主机）

2026-08-18 在本机 macOS 网络环境对识别模型压缩包分别请求前 2 MiB，三个源都返回 HTTP `206` 并成功收到
2,097,152 bytes：

| 源 | HTTP | 耗时 / 速度 |
| --- | --- | --- |
| GitHub 直连 | `206` | 5.812 s / 360,833 B/s |
| `ghfast.top` | `206` | 4.794 s / 437,475 B/s |
| `gh-proxy.com` | `206` | 6.605 s / 317,526 B/s |

这只证明当前 macOS 主机上的源可达和分段响应正常，不能替代国内 Windows 用户网络复测；代码仍按
GitHub → `ghfast.top` → `gh-proxy.com` 顺序 fallback，未增加第四源。

## Android 真机

准备：打开 USB 调试，确认设备可见；首次运行允许网络和麦克风权限。

```bash
cd app
flutter devices

# 默认下载模型并使用模型包内的 yue.wav；录音 15 秒。
flutter test integration_test/device_acceptance_test.dart -d <android-device-id> \
  --dart-define=VSASR_DEVICE_LABEL=Pixel-8 \
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
至少应保存以下信息：`device_label`（建议填写设备型号）、Android 版本、线程数、模型准备耗时、模型目录占用、进程 RSS
当前值/峰值、文件 RTF、麦克风 RTF 和是否出现持续积压。若只运行模拟器，必须在记录中标注“非真机结果”。

### Android release APK 安装启动补充基线（非真机）

2026-08-18 在 API 35 ARM64 `emulator-5554` 上构建并安装个人使用 release APK：
`versionName=1.0.2`、`versionCode=999`、APK 大小约 178.6 MB。使用
[`scripts/android_apk_install_smoke.sh`](scripts/android_apk_install_smoke.sh) 清除旧应用数据后安装，
通过 `apksigner` 确认 v2 签名，确认 APK 不包含模型文件，再直接启动 `.MainActivity`；应用进程保持运行 8 秒，
冷启动验收通过。该脚本只证明 release 包在当前 API 35 模拟器可安装和启动，不替代 Android 真机性能、内存、
麦克风和厂商 Codec 验收。

发布工作流 [`release.yml`](.github/workflows/release.yml) 已在 Android 产物校验后接入同一脚本：使用 API 35
`google_apis` x86_64 模拟器，先启用 KVM，再安装并冷启动待发布 APK，job 总时限为 30 分钟。该云端 smoke
只作为发布包的自动安装/启动基线；2026-08-18 的手动 `v1.0.2` 发布 run
[`32082049856`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32082049856) 全部通过，Android job
实际完成安装、冷启动和 8 秒进程存活检查，并将 Release 资产更新到提交 `5d64f49`。该结果不能替代真机验收。

可复用命令（从仓库根目录执行）：

```bash
cd app
flutter build apk --release --build-name 1.0.2 --build-number 999
cd ..
ADB_BIN=adb ./scripts/android_apk_install_smoke.sh \
  app/build/app/outputs/flutter-apk/app-release.apk emulator-5554
```

### API 35 ARM64 模拟器基线（非真机）

2026-08-18 在 `emulator-5554`（`sdk_gphone64_arm64`，Android 15 / API 35，软件渲染）按当前工作树复测
同一验收入口；未传入视频和麦克风参数，因此这两项明确跳过。模型下载、解压和完整性校验通过，
文件识别测试也通过：

| 指标 | 结果 |
| --- | --- |
| 配置 | `auto`，2 线程 |
| 模型准备 | 83,561 ms；模型目录 241,150,289 bytes |
| 完整性 | `model.verified=true`；测试后 241,151,027 bytes |
| 模型准备后 RSS | 当前 412,602,368 bytes；峰值 449,032,192 bytes |
| 文件 | `yue.wav`，82,368 samples，5.148 s |
| 解码 / 识别耗时 | 9 ms / 138 ms |
| 文件 RTF | `0.026807` |
| 识别结果 | `呢几个字都表达唔到，我想讲嘅意思。` |

可复用命令：

```bash
cd app
flutter test integration_test/device_acceptance_test.dart -d emulator-5554 \
  --dart-define=VSASR_DEVICE_LABEL=Android-API35-emulator
```

这份数据只说明 API 35 模拟器上的功能和基线性能，不移除 M10 的 Android 真机性能、内存、
实时 RTF 待验收项，也不能推断中低端真机或厂商 Codec 表现。

### API 35 ARM64 模拟器视频补充基线（非真机）

随后使用 `/data/local/tmp/m10-device-acceptance.mp4`（H.264 + AAC，320×180，约 3 秒）
再次运行同一入口，模型完整性和文件识别仍通过；视频音轨解码、播放器打开及播放推进也通过：

| 指标 | 结果 |
| --- | --- |
| 音轨 | 48,128 samples |
| 音轨解码 | 528 ms |
| 播放器打开 | 146 ms |
| 播放器读取时长 | 3.021 s |
| 麦克风 | 未设置 `VSASR_DEVICE_TEST_MIC_SECONDS`，明确跳过 |

视频项仍是 API 35 模拟器的软件渲染结果，不替代 Android 真机的播放性能或厂商解码器验收。

### API 35 ARM64 模拟器麦克风补充基线（非真机）

2026-08-18 在同一 `emulator-5554` 上传入 `VSASR_DEVICE_TEST_MIC_SECONDS=5`，先完成系统麦克风授权，
再从录音流建立后开始计时。这样不会把首次权限对话框的等待时间误计入实时 RTF。模拟器没有人工讲话输入，
因此这次只验证录音采样、实时识别管线收尾和积压判定，不用于判断语音识别质量：

| 指标 | 结果 |
| --- | --- |
| 配置 | `auto`，2 线程；请求 5.0 s |
| 实际采样 | 78,848 samples，4.928 s |
| 录音流建立后的会话耗时 | 5,031 ms |
| 麦克风 RTF | `1.020901` |
| 最大允许 RTF / 持续积压 | `1.25` / `false` |
| 产出段数 | 0（模拟器未提供人工讲话） |

可复用命令（首次运行若出现系统权限框，先允许麦克风）：

```bash
cd app
flutter test integration_test/device_acceptance_test.dart -d emulator-5554 \
  --dart-define=VSASR_DEVICE_LABEL=Android-API35-emulator-microphone \
  --dart-define=VSASR_DEVICE_TEST_MIC_SECONDS=5
```

该结果仍是 API 35 模拟器基线；Android 真机的麦克风输入、实时 RTF、内存和厂商音频栈差异仍待验收。

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
$env:VSASR_DEVICE_LABEL = "Windows-clean-user-desktop"
$env:VSASR_DEVICE_TEST_VIDEO = "C:\path\to\acceptance.mp4"
$env:VSASR_DEVICE_TEST_REPORT = "$env:LOCALAPPDATA\VoiceSmallASR\device_acceptance_report.json"
flutter test integration_test/device_acceptance_test.dart -d windows
```

最终记录应区分“安装包手工结果”和“源码集成测试报告”，不能只用 Windows CI 的结果代替。

截至 2026-08-18，最新 `main` 的 Windows workflow run
[`32075654714`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32075654714) 已在
`windows-2022` 上通过完整模型 E2E 7 项：模型缓存恢复、WAV/m4a 原生解码、粤语 WAV/m4a 识别、
真实 MP4 播放/跳转/抽音轨识别和三句实时识别；日志记录粤语 WAV RTF `0.055`，实时识别定稿 4 句、
局部结果 4 条。该 run 同时通过桌面 smoke、硬字幕 smoke、Release 构建、运行时依赖和模型排除检查，
仍不能替代 Windows 用户桌面的干净目录安装和首次启动手工清单。

随后推送提交 `ba07d04` 的 Windows workflow run
[`32078081707`](https://github.com/2653533859/VoiceSmallASR/actions/runs/32078081707) 增加并通过安装包 smoke：
把未签名安装包静默安装到空目录，验证 `vsasr_app.exe`、四个运行时 DLL 和模型文件排除，再用隔离的
`APPDATA`/`LOCALAPPDATA` 启动已安装程序并保持运行 8 秒。该结果证明 CI 产物可以实际安装和启动，
但 `windows-2022` runner 仍不等于用户自己的 Windows 桌面，手工清单继续保留。

## 结果判定

自动化报告满足以下条件后，才可把对应子项从 M10 的待验收列表移除：

1. `model.verified` 为 `true`，且模型准备过程没有复用截断或校验错误的缓存。
2. 文件转写有有效音频时长和 RTF；模型准备耗时、模型目录占用、进程 RSS、设备标识和实际线程配置已记录。RSS 是进程驻留集大小，用于同一设备上的阶段对比，不等同于模型精确分配量。
3. Windows 用户桌面手工清单全部完成；Android 真机至少完成模型、麦克风和实时 RTF 记录。
4. 视频项不跳过时，报告包含真实 MP4 的音轨解码和播放器推进结果。

当前仓库已提供入口和报告格式，但本机仍没有 Android 真机或可操作的 Windows 用户桌面，
因此 M10 的真实环境状态仍保持“待实机验收”。
