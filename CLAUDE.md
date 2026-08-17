# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

本地离线的多语种（中/英/粤/日/韩）语音识别，输出带时间戳的分段与字幕。基于 sherpa-onnx 跑
SenseVoice-Small（int8 ONNX）+ silero-vad，纯 CPU，模型仅首次运行联网下载。

仓库有两端，共用同一个模型与同一套业务语义：

| 端 | 位置 | 状态 |
| --- | --- | --- |
| Python 库 + CLI | `src/voice_small_asr/` | 已完成，107 项测试 |
| Flutter 三端客户端（Windows/macOS/Android） | `app/` | **M1、M2、M3、M5 已完成，M4 翻译基础、批量流程、双语导出、第三方 API provider 与应用内翻译工作流已完成，M6 设置页与模型管理首期已完成，M7 已完成 macOS 无签名包、Android APK/AAB 和 Windows Release/安装包构建验证，M8 发布质量基线代码已落地，M9 无签名翻译体验已完成，M11 项目文件数据层、首页保存/打开和最近项目首项已完成**：文件转写、实时字幕、视频播放、字幕联动与字幕校对编辑（171 项 `flutter test` + Android API 35 模拟器端到端 7 项 + Windows runner 完整模型端到端 7 项）。macOS/Android 模拟器/Windows CI 真实 mp4 已验收，Android 真机性能和 Windows 用户桌面运行仍待验证；真实翻译验收为个人使用范围外的可选项 |

两端固定 sherpa-onnx **1.13.5**，因此识别结果应逐字一致 —— **Python 端是 Flutter 端的对照基准**。
阶段计划（M0–M9）、待决策事项与踩坑记录在 `DEVELOPMENT_PLAN.md`，动 Flutter 端前先读。

## 常用命令

Python 端（仓库根目录，用 uv 管理）：

```bash
uv sync --extra mic            # 装依赖，mic = sounddevice（麦克风）
uv run vsasr download          # 下载模型（约 155 MB 压缩包 → 240 MB）

uv run ruff check .            # 静态检查（本项目的"type-check"等价物，无 mypy）
uv run ruff format .
uv run pytest                  # 全量：107 项
uv run pytest tests/test_subtitles.py::test_short_segment_is_not_split   # 单个测试
uv run pytest -k cantonese     # 按名字筛
```

**无模型时 `uv run pytest` 是 87 passed / 18 skipped**，这是正常状态：`tests/conftest.py` 的
`model_paths` fixture 在 `models.is_ready()` 为假时 skip 掉整组集成测试。改动 `engine.py` /
`vad.py` / `streaming.py` 后必须先 `vsasr download`，否则真正验证识别行为的 18 项根本没跑。
`tests/test_models.py` 用 `_FakeResponse` 替身打桩 `urllib.request.urlopen`，不发真实网络请求 —— 新增下载相关测试沿用这个模式。

Flutter 端：

```bash
# 国内先设这个：storage.googleapis.com 实测约 100 KB/s（Flutter 自身要下引擎产物）
export FLUTTER_STORAGE_BASE_URL=https://mirrors.cloud.tencent.com/flutter
export PATH="$HOME/development/flutter/bin:$PATH"   # 本机 Flutter 3.47.0 装在这里

cd app && flutter pub get
flutter analyze                # 验收标准：No issues found
flutter test                   # 171 项，不需要模型也不需要设备
flutter test --plain-name "yue.wav 解出的采样数与文件头自洽"   # 跑单个
flutter build apk --release   # Android release APK；需要 Android SDK/JDK
flutter build appbundle --release # Android release AAB；无签名变量时使用 debug signing 做构建验证
# 正式 Android 签名：四个 VSASR_ANDROID_* 变量必须全部设置，缺一会直接失败
VSASR_ANDROID_KEYSTORE_FILE=/secure/release.jks \
VSASR_ANDROID_KEY_ALIAS=voice-small-asr \
VSASR_ANDROID_KEYSTORE_PASSWORD='...' \
VSASR_ANDROID_KEY_PASSWORD='...' \
flutter build appbundle --release
flutter build macos --debug     # 常规签名构建需开发证书；个人使用可用无签名脚本
flutter run -d macos           # 常规运行可能需开发证书；个人使用可用无签名构建脚本
FLUTTER_BIN=/path/to/flutter/bin/flutter ./scripts/build_macos_unsigned.sh  # 生成无签名 .app/.dmg
# Windows Release + Inno Setup 安装包：由 GitHub Actions windows-2022 runner 执行
pwsh -File scripts/build_windows_unsigned.ps1 -Flutter flutter

# 端到端验收：真模型 + 真引擎 + 真原生解码 + 实时识别 + 真实视频播放，7 项（素材要先放进沙盒容器，见 DEVELOPMENT_PLAN §7）
flutter test integration_test/e2e_test.dart -d macos
# Windows 完整模型 e2e（GitHub Actions 手动触发，首次下载模型较慢）
gh workflow run windows-build.yml --ref main -f run_full_e2e=true
# 可选：旧 DeepL 兼容验收（个人使用可跳过；密钥文件必须在仓库外）
flutter test integration_test/deepl_acceptance_test.dart -d macos \
  --dart-define-from-file=/path/to/voicesmallasr-deepl.env
```

**不要设 `PUB_HOSTED_URL`。** pub.dev 本身可直连；一旦指向镜像，`flutter pub get` 会把
`app/pubspec.lock` 里每个包的 `url` 重写成镜像地址并重新解析依赖（实测 92 个包全被改动）。
如果不小心设了并跑过 pub get，`git checkout app/pubspec.lock` 后不带该变量重跑一次。

**本机可验证的范围（2026-08-16 起）：`flutter analyze`、`flutter test`、Android release APK/AAB 构建，以及 macOS 的个人使用无签名编译与打包。**
Xcode 26.6 + CocoaPods 1.17.0 已装，无签名模式的 `xcodebuild` 已成功编译，
所以 `app/macos/Runner/MainFlutterWindow.swift` 里的 Swift 原生解码、media_kit 播放插件和
`flutter_secure_storage_darwin` **已经编译过**；普通 `flutter build macos --debug` 仍需要开发证书，
但个人使用的无签名 `.app`/`.dmg` 不依赖该证书。
Android 的 Kotlin 已随 release APK/AAB 编译验证，并在 API 35 ARM64 模拟器端到端跑通；本机没有 Android 真机，不能据此声称中低端设备性能已验证；Windows 的 C++ 已在 GitHub Actions `windows-2022` runner 的 MSVC 环境编译通过，并通过桌面 smoke 与完整模型 e2e，但用户桌面运行仍未验证。`DEVELOPMENT_PLAN.md` 记录的另一台开发机是 Windows（`E:\dev\flutter`）。

## 架构

### 分层铁律

**sherpa-onnx 的原生类型只允许出现在 `engine.py` / `vad.py`（Dart：`asr_engine.dart` / `vad_session.dart`）里。**
跨层一律传 `Segment` / `Word` / `TranscriptionResult` 这类纯数据对象。字幕层、CLI、UI、未来的翻译层都不感知推理框架。
Python 端公开 API 全部收在 `src/voice_small_asr/__init__.py` 的 `__all__`，新增对外能力要同步在那里导出。

### 数据流

```
音频文件/麦克风 → audio.load / iter_microphone      （统一成 16 kHz float32 单声道 mono）
      → vad.iter_speech / VadSession                （切句，给段级时间戳）
      → Recognizer.decode(_batch)                   （SenseVoice 解码，出 token 级时间戳）
      → Segment / TranscriptionResult               （对外契约）
      → subtitles.render/write                      （SRT / VTT / JSON / TXT）
```

### 流式的真实语义

SenseVoice 是**非流式**模型。`streaming.py` 的 `StreamingTranscriber` 用 VAD 造出流式体验：

- `is_final=True`：VAD 判定一句说完后解码，时间戳可靠，`index` 从 0 递增 → 可写字幕；
- `is_final=False`：说话过程中每隔 `partial_interval`（默认 0.6s）对当前句**整句重解码**，`index=-1` → 只供 UI 即时上屏，随后被同句定稿结果替换。

集成方按 `is_final` 决定覆盖还是追加（CLI 的 `_show_live` 就是范例）。延迟因此是 0.6 秒级，不是逐字级；
要改成逐字流式必须换模型（zipformer），代价是丢掉粤语 —— 而粤语是本项目的硬需求，不要擅自换。

Dart 侧的 `streaming_transcriber.dart` 语义相同，但多两件事：Dart 绑定没有 `currentSegment`，
当前句的音频缓冲要自己攒；而且 VAD 要连续听到 `minSpeechDuration` 才认定「在说话」，
那之前的窗口已经喂进去了，所以额外保留 0.5 秒回看窗口（`kPartialLookbackSeconds`）补上句首，
否则局部结果缺开头几个字（定稿段不受影响 —— 那是 VAD 自己吐出来的完整句子）。

### 模型管理与离线

`models.py` 负责下载/解压/就绪检查，目录结构固定（`resolve_paths` 与 Dart 的 `resolvePaths` 必须保持一致）：

```
<模型目录>/silero_vad.onnx
<模型目录>/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/{model.int8.onnx,tokens.txt}
```

Python 端目录解析优先级：`ASRConfig.model_dir` → 环境变量 `VSASR_MODEL_DIR` → `~/.cache/voice-small-asr/models`。
Flutter 端在 `getApplicationSupportDirectory()/models`。
两端各自维护一份**同源同序**的下载源列表（`models.BASE_URLS` ↔ `kModelBaseUrls`：GitHub → ghfast.top → gh-proxy.com），
逐源尝试、任一成功即止，截断响应视为该源失败。**增删源必须两端同步改**，否则"两端行为一致"的前提就断了。
三个源已实测可达（2026-08-15，macOS 机器），但国内网络下未验证。
生产/离线场景传 `allow_download=False`，缺模型立刻失败而不是隐式联网。

### 两端文件对应关系

改了一端的行为语义，另一端要同步，否则"Python 作为基准"就失效了：

| Python | Dart |
| --- | --- |
| `config.py` | `app/lib/src/asr/asr_config.dart` |
| `segments.py` | `app/lib/src/asr/segment.dart`（多 `translation` 字段） |
| `models.py` | `app/lib/src/asr/model_manager.dart` |
| `vad.py` + `engine.py` 的 token 处理 | `app/lib/src/asr/vad_session.dart` |
| `engine.py` | `app/lib/src/asr/asr_engine.dart` |
| `audio.py`（soundfile 直读 wav） | `app/lib/src/audio/wav.dart`（纯 Dart，可单测） |
| `audio.py`（ffmpeg 解压缩格式/视频） | `app/lib/src/audio/audio_decoder.dart` → 平台原生通道 |
| `audio.py`（`iter_microphone`） | `app/lib/src/audio/microphone.dart`（`record` 包） |
| `subtitles.py` | `app/lib/src/subtitles/subtitles.dart`（多双语字幕） |
| `streaming.py` | `app/lib/src/asr/streaming_transcriber.dart` |
| —（Python 端不需要） | `app/lib/src/asr/transcription_worker.dart`：后台识别 isolate |
| `cli.py`（人机界面） | `app/lib/src/ui/`：`transcribe_controller.dart` / `live_controller.dart` 两个状态机 + `home_page.dart` |

**界面层只跟两个控制器打交道**：`TranscribeController` 管文件转写（模型准备 → 解码 → 识别 → 导出），
`LiveController` 管麦克风实时字幕（借 worker → 开设备 → 局部/定稿段）。依赖都可注入
（前者 `decoder` / `models` / `launch`，后者 `provideWorker` / `mic`），widget 测试正是靠这个跑通全流程。
控制器只渲染字幕文本（`renderResult`），落盘交给界面层的 `SaveFile` —— 三端保存对话框差异太大
（Android SAF、macOS sandbox），不该混进状态机。

**两个页签共用同一个识别 worker**：模型 240 MB，加载两份在手机上直接爆，
所以 `LiveController` 不自己起 isolate，而是通过 `TranscribeController.ensureWorker()` 借。
同一时刻只允许一路实时会话（`startLive()` 会拒绝第二路）。

**识别一律走 `TranscriptionWorker`（后台 isolate），不要在 UI isolate 上直接调 `AsrEngine`。**
sherpa-onnx 的解码是同步 FFI 调用，`await` 让不出去。分工：主 isolate 解码音频
（平台通道只在 root isolate 可用）→ `Float32List` 送进 worker → 收回纯数据结果。
worker 的工厂参数 `TranscriberFactory` 必须是顶层/静态函数（闭包过不了 isolate 边界），
测试正是靠替身工厂在没有原生库的环境里跑通整条链路。

**音频解码的两端差异是有意的**：Python 端调系统 ffmpeg，Dart 侧没有可用的 ffmpeg 封装
（`ffmpeg_kit_flutter` 已弃养且不支持 Windows），因此定为三端各写原生解码，
通道名 `vsasr/audio_decoder`，方法 `decodeToPcm16k`，入参 `{'path': String}`，
回 16 kHz 单声道 float32（`Float32List` 或小端字节流都接受）。
目前三端都已实现：macOS `macos/Runner/MainFlutterWindow.swift`（AVAssetReader，混声道与重采样交给
AVFoundation）、Android `android/.../MainActivity.kt`（MediaExtractor + MediaCodec，混声道与重采样自己做）、
Windows `windows/runner/audio_decoder.cpp`（IMFSourceReader，先要 16 kHz 单声道 float32，被拒则自己算）。
macOS 那份**已编译验证**（无签名 `xcodebuild` 通过），Android Kotlin 已随 release APK/AAB 编译并在 API 35 ARM64 模拟器端到端验证；
Windows C++ 已在 MSVC CI 编译并通过 AAC/MP4 桌面 smoke 与完整模型 e2e；Android 真机性能与 Windows 用户桌面运行仍未验证。
重采样在 `wav.dart`、Kotlin、C++ 里各有一份线性插值实现，三者必须逐行等价 —— 改一处要同步另两处。
原生侧未注册通道时 Dart 侧会抛出带指引的 `AudioDecodeException`，不会静默返回空音频。

Dart 绑定的能力缺口（不是 bug，别去"修"）：没有 `decodeStreams`（只能逐段解码）、没有 `currentSegment`
（局部结果要自己维护缓冲区）、没有 `durations`（token 结束时间取下一个 token 起点）。
Dart 侧持有原生指针的对象必须手动 `free()`，都收在 `dispose()` 里。

## 已踩过的坑（改相关代码前务必先看）

- **`sherpa-onnx` 与 `sherpa-onnx-core` 必须同版本且都显式声明**。PyPI 元数据没声明 core 依赖，缺它时扩展模块会退回加载系统旧版 `onnxruntime`，报 `requested API version [27] is not available` 后**直接段错误**。`pyproject.toml` 里已固定并注释，不要"清理"掉。
- **模型固定 2024-07-17 版**，2025-09-09 版不支持标点，无法用于字幕。
- **`requires-python` 下限是 3.11.4**（`tarfile` 的 `filter="data"` 在 3.11 系列到 3.11.4 才回补）。
- **不能整段一次性喂 VAD**，必须按 `window_size`(512) 分批，否则段起点判定失准。
- **Python 端 `detector.front` 返回内部对象引用**，必须在 `pop()` 之前把 samples 拷出来（Dart 侧已内部拷贝，无此坑）。
- **纯空格 token 不能丢**。SenseVoice 把英文词间空格作为独立 token 输出，去标签后判空要用 `if not token`，用 `token.strip()` 会把字幕拼成 `with50`。
- **局部结果的节流时刻要在解码之后记**（`streaming.py` 里有注释）：用解码前的时刻会导致每个音频块都触发一次重解码，吃满 CPU 并拖慢定稿。
- **下载必须比对 `Content-Length`**：连接中断时 `read()` 只返回 `b''` 不抛异常，截断文件会被当成有效缓存；**坏压缩包解压失败后必须删掉**，否则每次运行都以同样方式失败。
- **但两个镜像源常走 chunked 编码、不给 `Content-Length`**，那条比对此时形同虚设，只能退回 `min_bytes` 保守下限（`models.py` 的 `ModelSpec.min_bytes` ↔ `model_manager.dart` 的 `kAsrArchiveMinBytes`/`kVadModelMinBytes`，**两端同步改**）。`silero_vad.onnx` 没有解压环节兜底，半截文件会永久缓存。
- **`http.client.IncompleteRead` 不是 `OSError`**（继承 `HTTPException`），只 `except OSError` 会让第一个镜像断连时异常穿出去，后两个源根本不试。
- **解析 wav 的 chunk 要按裁剪后的长度前进**：`data` 的 size 写成 0 时按声明值前进等于原地不动，会把 PCM 当 chunk 头解析，静默丢音频。
- **原生解码器不能有「不回包」的路径**（Dart 的 `invokeMethod` 不超时，界面会永久卡住）：Kotlin 捕获 `Throwable` 而非 `Exception`（OOM 是 `Error`），Windows 的 `PostMessageW` 失败要就地回包。
- **macOS 解码只喂第一条音轨**：`AVAssetReaderAudioMixOutput` 拿到全部音轨会把双语视频混成一条，与 Android/Windows/Python 的单轨行为不一致。
- **Dart 侧 `initBindings()` 每个 isolate 都要单独调用**；240 MB 模型解压必须放 isolate 流式落盘，否则手机上 OOM。
- **识别 isolate 也要平台通道**：`ModelManager` 靠 path_provider 找目录，因此 worker 启动时必须
  `BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken)`，否则抛
  "BackgroundIsolateBinaryMessenger.instance value is invalid"。这个坑只有端到端测试能暴出来。
  接上之后 isolate 不会自己退出（常驻端口挂着），收尾必须 `Isolate.exit()`，且**先 free 原生资源**。
- **`file_picker` 12 没有 `FilePicker.platform`**：改成静态 `FilePicker.pickFile()` /
  `FilePicker.saveFile()`，后者要求传字节并自己落盘，返回 `Uri?`。别再自己写文件。
- **导出要 `files.user-selected.read-write` entitlement**，只给 read-only 时选完路径也写不进去。
- **沙盒应用只能读自己的容器**：集成测试素材不能放 `/tmp`，要放进
  `~/Library/Containers/<bundle-id>/Data/Library/Application Support/<bundle-id>/models/`。
- **macOS sandbox 静默掐出网**：entitlements 缺 `network.client` 时模型下载像网络故障一样失败，没有权限报错；`files.user-selected.read-only` 缺了则 file_picker 选的文件读不出来。Debug/Release 两个 entitlements 都要改。
- **Android release 包会丢 `INTERNET` 权限**：模板只在 debug/profile 的 manifest 里声明它，`main/AndroidManifest.xml` 必须自己写。
- **给 macOS Runner 加 Swift 文件要同时改 `project.pbxproj`**，手改易坏，所以原生解码器写在已在编译列表里的 `MainFlutterWindow.swift` 内。
- **`--device` 纯数字要转 `int`**：sounddevice 把 `str` 当设备名子串搜索。
- **macOS 构建会因 pub 抹掉符号链接而失败**：`sherpa_onnx_macos` 的
  `SherpaOnnxC.xcframework/macos-arm64_x86_64/SherpaOnnxC.framework` 是 macOS 的**版本化**
  framework，正常靠 `Versions/Current` 等符号链接组织；pub 包不支持符号链接，解压后它们变成
  三份真实副本（163 MB），bundle 结构不合法，`codesign` 报
  `code object is not signed at all`、构建直接失败。修法是在 pub cache 里恢复符号链接：

  ```bash
  F=~/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.5/macos/sherpa_onnx_macos/SherpaOnnxC.xcframework/macos-arm64_x86_64/SherpaOnnxC.framework
  cd "$F" && rm -rf Versions/Current Headers Modules Resources SherpaOnnxC
  ln -s A Versions/Current
  for n in Headers Modules Resources SherpaOnnxC; do ln -s "Versions/Current/$n" "$n"; done
  ```

  改的是共享缓存，`flutter pub cache repair` 或换机器后会复现，属于必踩的一步（顺带把 163 MB 降到 54 MB）。
- **macOS 缺 `NSMicrophoneUsageDescription` 是直接闪退**，不是弹授权框：系统在进程请求麦克风时才查这条 Info.plist，缺了就 SIGKILL，控制台里也没有权限报错。它与 entitlements 的 `device.audio-input` 是两回事（后者是沙盒开关），两者都要有。
- **不需要 `permission_handler`**：`record` 的 `hasPermission()` 本身就会发起运行时申请，多引一个包只是多一套要同步的平台配置。
- **实时会话的段必须在 `done` 之前送出**：worker 里 `finish()` 先把 flush 出的段 `add` 进流再 `close`，`await close()` 会等先前排队的事件送达，跨 isolate 也不乱序；反过来先 close 再 add，尾句直接丢掉。
- **录音期间不要挂不定量进度条**：`LinearProgressIndicator()` 一直调度新帧，几十分钟的录音会让界面永远在动画中，widget 测试表现为 `pumpAndSettle` 超时。只在准备/收尾这两个过渡态显示。
- **widget 测试里 Stream 的 `close()`/`cancel()` 推不动**：`tester.pump()` 是 fake async，这些 Future 只在真实事件循环上完成。停止录音要等麦克风流关闭、会话关闭、两个订阅取消，测试里得 `await tester.runAsync(() => Future.delayed(Duration.zero))` 走几轮。
- **切语言时旧 isolate 还在关，新的不能抢先加载**：`setLanguage` 一置空 `_worker`，`prepare()` 就会立刻起新 isolate，两份 240 MB 模型同时驻留。已改成记下正在关闭的 Future，`prepare()` 先 await 它。
- **`record` 的 `dispose()` 是终局**：平台侧的录音器实例被销毁，同一个 `AudioRecorder` 之后再 `startStream()` 就失败。「开始 → 停止 → 再开始」是常规用法，所以 `MicrophoneSource` 每场录音新建一个录音器、停止时销毁。替身也要照做，否则这条路径在测试里是假的。
- **`dispose()` 里的每一步收尾都要有上限**：worker 关闭时先等实时会话 `finish()`，isolate 卡住时它永远不返回，连后面「超时硬杀」的兜底都走不到。

## 代码约定

- 注释、文档字符串、错误信息、CLI 输出**全部中文**；面向用户的异常在 `cli.py::main` 里被收成一行"错误：…"，不抛 traceback。
- ruff：line-length 100，`select = ["E","F","I","UP","B"]`，`target-version = py311`。
- **Dart 侧不跑 `dart format`**：现有文件在 80 与 100 两种宽度下都不是 formatter 输出（手工对齐，行宽 ≤100），
  只以 `flutter analyze` 零告警为准。别顺手全量格式化，那会产生一大片无关 diff。
- 对外数据类用 `@dataclass(frozen=True, slots=True)`（`TranscriptionResult` 可变，不 frozen）。
- 进度、日志、统计写 **stderr**，转写结果写 **stdout** —— 这样 `vsasr transcribe x.wav > out.srt` 才是干净的。
- `models/` 与 `data/` 只保留 `.gitkeep`，音频与权重一律不入库（`.gitignore` 已覆盖）。
- `.gitattributes` 固定 `eol=lf`，不要提交 CRLF。
