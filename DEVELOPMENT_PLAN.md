# VoiceSmallASR 后续开发计划

> 更新日期：2026-08-15　　当前版本：0.1.0

## 1. 现状速览

项目分两端，共用同一套模型与同一套业务语义：

| 端 | 技术栈 | 状态 | 用途 |
| --- | --- | --- | --- |
| **Python 端** | Python 3.11.4+ / sherpa-onnx 1.13.5 | ✅ 已完成，97 项测试通过 | CLI 工具、服务端集成、批处理 |
| **Flutter 端** | Flutter 3.47.0 / Dart 3.13.0 / sherpa_onnx 1.13.5 | 🚧 引擎层完成，UI 未开始 | Windows / macOS / Android 图形界面 |

两端用的是**同一个模型、同一个 sherpa-onnx 版本**（1.13.5），因此识别结果一致，Python 端可以作为 Flutter 端的对照基准。

### 已验证的能力（Python 端实测）

| 音频 | 时长 | 耗时 | RTF | 结果 |
| --- | --- | --- | --- | --- |
| zh | 5.59s | 0.20s | 0.035 | 开饭时间早上9点至下午5点。 |
| en | 7.15s | 0.24s | 0.033 | The tribal chieftain called for the boy. / And presented him with 50 pieces of gold. |
| ja | 7.20s | 0.23s | 0.032 | うちの中学は弁当制で持っていけない場合は五十円の学校販売のパンを買う。 |
| yue | 5.15s | 0.14s | 0.028 | 呢几个字都表达唔到，我想讲嘅意思。 |

粤语一行是选型的验证点：`呢`/`唔`/`嘅` 被保留，没有被转写成书面普通话。

## 2. 架构

```
VoiceSmallASR/
├── src/voice_small_asr/        Python 库 + CLI（已完成）
│   ├── config.py               ASRConfig / VADConfig
│   ├── models.py               模型下载、解压、缓存、就绪检查
│   ├── audio.py                加载/重采样（ffmpeg）/分块/麦克风
│   ├── vad.py                  silero-vad 封装
│   ├── engine.py               SenseVoice 解码 + 整段转写
│   ├── streaming.py            VAD 驱动的流式识别
│   ├── segments.py             Word / Segment / TranscriptionResult
│   ├── subtitles.py            SRT / VTT / JSON / TXT
│   └── cli.py                  download / transcribe / live / devices
├── app/                        Flutter 三端客户端
│   └── lib/src/
│       ├── asr/
│       │   ├── asr_config.dart      ← 对应 config.py
│       │   ├── segment.dart         ← 对应 segments.py（多 translation 字段）
│       │   ├── model_manager.dart   ← 对应 models.py
│       │   ├── vad_session.dart     ← 对应 vad.py
│       │   └── asr_engine.dart      ← 对应 engine.py
│       └── subtitles/subtitles.dart ← 对应 subtitles.py（多双语字幕）
├── examples/                   Python 集成示例
├── tests/                      Python 测试（97 项）
└── DEVELOPMENT_PLAN.md         本文档
```

分层原则：**sherpa-onnx / sherpa_onnx 的原生类型只出现在 `engine`/`vad` 层**，对外一律是 `Segment` / `TranscriptionResult` 这类纯数据对象。UI 层与翻译层都不感知推理框架。

## 3. 已完成

### Python 端（可用于生产）

- 整段转写、VAD 分段、批量解码，RTF ≈ 0.03
- 流式识别：临时结果 + 定稿双轨输出
- 段级 + token 级时间戳
- SRT / VTT / JSON / TXT 导出，长段按时间戳与时长上限切分
- 模型首次联网下载并缓存，之后完全离线；支持离线目录部署
- CLI 四个子命令；三个集成示例（含服务端复用模式）
- 97 项测试，单元测试与模型集成测试分层

### Flutter 端（引擎层，`flutter analyze` 无告警）

- 三端工程骨架（windows / macos / android）
- 70 个依赖，含 `sherpa_onnx 1.13.5` 全部平台原生库子包
- Gradle 国内镜像（阿里云 Maven + 腾讯云 Gradle 发行版）
- 六个引擎文件移植完成，Python 端修过的 bug 一并带过来：
  - 空格 token 不能丢（否则英文字幕拼成 `with50`）
  - 无 token 时间戳的长段要遵守时长上限
  - 下载要比对 `Content-Length`，截断文件不能当有效缓存
  - 坏压缩包解压失败后必须删除，否则永远复用

### 环境（本机，全部在 E 盘）

```
E:\dev\flutter        Flutter 3.47.0 stable / Dart 3.13.0
E:\dev\android-sdk    platforms 36 + 37.0、build-tools 36.1.0、platform-tools
```

## 4. 阶段计划

每个阶段都以「能跑起来给人看」为验收标准，不做只有代码没有验证的阶段。

### M0 · 解除构建阻塞（前置，需要人工介入）

| 事项 | 说明 | 谁做 |
| --- | --- | --- |
| 开启 Windows 开发者模式 | Flutter 构建带插件项目需要符号链接权限。`start ms-settings:developers` | 用户（需权限） |
| Visual Studio C++ 工具链 | Windows 桌面构建必需，约 5–7 GB，安装会弹 UAC | 用户授权后由 AI 执行 |
| Android 真机或模拟器 | 目前 `adb devices` 为空。真机最快；模拟器需再下 ~1.5 GB 系统镜像 | 用户插机器 / AI 装模拟器 |

**M0 不完成，M1 之后的所有阶段都无法验证。** 其中开发者模式必须由有管理员权限的人开启。

### M1 · 最小闭环：文件转写 + 字幕导出

目标：选一个音频文件 → 识别 → 看到分段与时间戳 → 导出 SRT。

- [ ] 音频解码层（见 §5 待决策 1）：文件 → 16 kHz float32 单声道
- [ ] `AsrEngine` 放入 isolate，避免长音频卡 UI；`initBindings()` 需在每个 isolate 内单独调用
- [ ] 文件选择（`file_picker`）、进度条、分段列表、导出对话框
- [ ] 模型首次下载页：进度、失败重试、多源 fallback 提示
- [ ] 验收：同一个 `test_wavs/yue.wav` 在 Flutter 端与 Python 端输出**逐字一致**

### M2 · 麦克风实时字幕

- [ ] `record` 包取 PCM stream → `VadSession`
- [ ] 自维护 partial 缓冲区（Dart 绑定没有 `currentSegment`，见 §6）
- [ ] 临时结果原地刷新、定稿追加的列表 UI
- [ ] Android 麦克风权限（`permission_handler`）
- [ ] 验收：说三句话，三句都定稿且时间戳连续；Android 真机不掉帧

### M3 · 视频播放 + 字幕叠加

- [ ] 播放器（`video_player` 或 `media_kit`，需评估 Windows/macOS/Android 一致性）
- [ ] 从视频抽音轨 → 识别 → 字幕轨
- [ ] 播放进度与字幕高亮联动，点字幕跳转
- [ ] 验收：一段带外语对白的 mp4，播放时字幕跟得上、点击可跳转

### M4 · 翻译（识别语言 → 中文）

- [ ] `TranslationProvider` 抽象：`Future<List<String>> translate(List<String> texts, {String? from, String to})`
- [ ] 在线 provider 实现（首期，见 §5 待决策 2）
- [ ] 批量翻译 + 失败重试 + 进度回报；结果写入 `Segment.translation`
- [ ] 双语字幕导出（`subtitles.dart` 已支持，接上即可）
- [ ] 验收：英/日视频生成中英双语 SRT，导出的文件在播放器里两行都正常显示

### M5 · 字幕校对编辑

- [ ] 可编辑列表：改文字、调起止时间、合并/拆分字幕条
- [ ] 撤销/重做
- [ ] 与播放器联动（编辑时定位到对应时间点）
- [ ] 验收：改完导出的 SRT 时间轴无重叠、无倒序

### M6 · 设置页与模型管理

- [ ] 语言、线程数、VAD 断句灵敏度、临时结果间隔
- [ ] 模型下载/删除/占用空间、离线模式开关
- [ ] 翻译 provider 配置（API key 用安全存储，不落明文）
- [ ] 验收：改设置后立即生效，重启后保留

### M7 · 打包分发

- [ ] Android APK / AAB（可在本机构建）
- [ ] Windows exe + 安装包（需 VS 工具链）
- [ ] **macOS `.app`/`.dmg` 必须在 Mac 上构建** —— Apple 的签名与打包工具链只存在于 macOS，本机（Windows）无法产出
- [ ] 模型不打进安装包（240 MB），首次运行下载

## 5. 待决策事项

### 待决策 1 · 音频解码（阻塞 M1）

Python 端靠 ffmpeg 解 mp3/m4a/视频。Dart 侧没有这个便利：`sherpa_onnx` 自带的 `readWave()` 只认 wav，而 M3 的视频字幕必须能从 mp4 抽音轨。

| 方案 | 能力 | 代价 |
| --- | --- | --- |
| `ffmpeg_kit_flutter` | 与 Python 端能力完全对齐，一套代码三端 | APK 体积 +20~40 MB；该包维护状态需先核实 |
| 平台原生解码（MediaCodec / AVFoundation / Media Foundation） | 体积零增长，性能最好 | 三端各写一份平台通道，工作量约 3 倍 |
| 只支持 wav + 让用户自己转码 | 零成本 | 不可接受，违背「选视频生成字幕」的需求 |

倾向：先用 `ffmpeg_kit_flutter` 打通 M1–M3，体积成为问题时再针对性替换为原生解码。**需要确认后再动手。**

### 待决策 2 · 在线翻译服务商（阻塞 M4）

已定方向：可插拔 provider 接口，首期在线。还需定具体服务商 —— DeepL（质量最好、有免费额度）、腾讯/百度（国内延迟低、需实名）、或 OpenAI/Claude 类 LLM（可带上下文，字幕连贯性更好）。选择影响 API key 管理与计费方式。

### 待决策 3 · 状态管理与项目文件格式（影响 M5）

字幕校对需要撤销/重做与「工程文件」概念（音频路径 + 分段 + 译文 + 编辑历史）。已引入 `provider`，但 M5 的编辑历史可能更适合 `riverpod` 或自建 command 栈。到 M5 前不必决定。

## 6. 已知技术约束与踩坑记录

这一节是给未来的自己看的 —— 都是实测踩过的，不要重踩。

### Python 端

- **`sherpa-onnx` 与 `sherpa-onnx-core` 必须同版本且都要显式声明。** PyPI 索引元数据没有声明 core 依赖，uv 不会自动装。缺了它扩展模块会退回加载 `C:\Windows\System32\onnxruntime.dll`（1.17.1），报 `requested API version [27] is not available` 后**直接段错误**。
- **`requires-python` 下限是 3.11.4 而非 3.11.0。** `tarfile` 的 `filter="data"`（PEP 706）在 3.11 系列直到 3.11.4 才回补。
- **VAD 的 `front` 返回内部对象引用**，必须在 `pop()` 之前把 samples 拷出来，否则拿到空数组。
- **不能整段一次性喂 VAD**，要按 `window_size`(512) 分批，否则段起点判定失准（实测整段喂时 5.15s 音频的段起点被判成 4.806s）。

### Flutter 端

- **Dart 绑定没有 `currentSegment`** —— 流式局部结果要自己维护缓冲区，起点会比 VAD 判定略晚。
- **Dart 绑定没有 `decodeStreams`** —— 只能逐段解码，靠 isolate 并行补性能。
- **Dart 绑定没有 `durations`** —— token 结束时间取下一个 token 的起点（SenseVoice 的 `durations` 实测本来就是空的，与 Python 端行为无差别）。
- **好消息：Dart 的 `vad.front()` 内部已拷贝 samples**，不存在 Python 端那个失效坑。
- **`initBindings()` 每个 isolate 都要单独调用**，否则抛 "Please initialize sherpa-onnx first"。
- **240 MB 模型解压必须放 isolate 流式落盘**，一次性读进内存在手机上会 OOM。

### 网络（中国大陆）

| 目标 | 直连 | 对策 |
| --- | --- | --- |
| `storage.googleapis.com`（Flutter SDK） | ✅ 431 ms | 无需镜像 |
| `dl.google.com`（Android SDK） | ✅ | 无需镜像 |
| `pub.dev` | ✅ | 无需镜像 |
| `maven.google.com`（Gradle 依赖） | ❌ 超时 | 阿里云镜像，已配 |
| `services.gradle.org`（Gradle 224 MB） | ✅ 但慢 | 腾讯云镜像，已配 |
| `github.com`（**模型下载**） | ❌ 超时 | `model_manager.dart` 已做三源 fallback（GitHub → ghfast.top → gh-proxy.com），**镜像可用性尚未实测，M1 时需验证** |

### 平台限制

- **macOS 安装包只能在 Mac 上构建**，本机（Windows）无法产出。
- **Windows 构建需要开发者模式 + Visual Studio C++ 工具链**，两者都需要管理员权限。
- 蓝牙耳机麦克风是 8 kHz 窄带，识别率明显低于设备自带麦克风。

## 7. 新机器上复现环境

```bash
# Python 端
uv sync --extra mic
uv run vsasr download          # 首次下载模型（约 155 MB 压缩包）
uv run pytest                  # 97 项应全绿

# Flutter 端
cd app
flutter pub get
flutter analyze                # 应为 No issues found
flutter run -d windows         # 需开发者模式 + VS C++ 工具链
flutter run -d <android-id>    # 需真机或模拟器
```

模型目录：Python 端在 `~/.cache/voice-small-asr/models`（可用 `VSASR_MODEL_DIR` 覆盖），Flutter 端在应用私有目录（`getApplicationSupportDirectory()/models`）。两端目前各存一份，如需共用可在设置页指定路径。

## 8. 主要风险

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| GitHub 模型下载在国内不通，镜像也失效 | 用户装完 App 拿不到模型，功能完全不可用 | M1 必须实测三个源；准备把模型镜像到国内对象存储或 ModelScope 作为第四源 |
| `ffmpeg_kit_flutter` 维护状态不明 | 音频解码方案落空，M1/M3 返工 | 决策前先核实包的最近更新与三端支持；预留原生解码作为备选 |
| Android 中低端机跑 int8 SenseVoice 太慢 | 实时字幕体验不可用 | 先在真机实测 RTF；必要时降低线程数、增大 VAD 分段、或只在桌面端提供实时功能 |
| 无 Mac 设备 | macOS 端始终无法验证与分发 | 代码保持三端一致，macOS 构建交由有 Mac 的人执行；或按需接入 CI 的 macOS runner |
