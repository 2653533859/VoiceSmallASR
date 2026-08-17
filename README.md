# VoiceSmallASR

本地离线的多语种流式语音识别：**中文 / 英文 / 粤语 / 日文 / 韩文**，输出带时间戳的分段与字幕文件，纯 CPU 推理，模型仅首次运行需联网下载。

- **多语种单模型** — 一个 228 MB 的 int8 模型覆盖 zh / en / yue / ja / ko，可自动检测语言
- **粤语是真粤语** — 保留 `呢` `唔` `嘅` 等粤语用字，而非转写成书面普通话
- **实时流式** — VAD 驱动，边说边出临时结果，句末自动定稿
- **时间戳** — 段级 + token 级（中日粤为单字，英文为词/子词）
- **字幕导入/导出** — 导入 SRT / VTT / JSON，导出 SRT / VTT / JSON / TXT，长句自动按时间戳切分
- **识别完全离线** — 下载模型后语音识别可断网使用；翻译是用户主动开启的第三方在线能力
- **易集成** — 库优先设计，公开 API 只有稳定的数据类，不泄漏底层推理框架类型

## 技术选型

| 组件 | 选择 | 理由 |
| --- | --- | --- |
| 识别模型 | SenseVoice-Small（int8 ONNX） | 非自回归，CPU 上极快；原生支持粤语；中文 CER 明显优于 Whisper |
| 推理运行时 | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 纯 onnxruntime，无 PyTorch 依赖；官方支持 12 种语言绑定，便于日后跨语言集成 |
| 端点检测 | silero-vad | 负责分句、触发流式识别、给出段级时间戳 |
| 音频解码 | soundfile + ffmpeg | wav/flac 直读；mp3/m4a/视频与重采样交给 ffmpeg |

**为什么不用 Whisper / faster-whisper**：Whisper 没有独立的粤语，会把粤语识别成中文并转写为书面普通话（`唔`→`不`、`嘅`→`的`、`呢`→`這`），而粤语是本项目的硬需求。中文 CER 上 SenseVoice 约 7.8%，Whisper-large-v3 约 20%。

**为什么不用 Qwen3-ASR / Nemotron 3.5 ASR streaming**：前者没有 CPU 推理路径（文档中全部示例为 CUDA），后者 40 个语言区不含粤语。本机无 NVIDIA GPU，因此都不适用。

**关于"流式"的实际含义**：SenseVoice 是非流式（离线）模型，本项目用 VAD 驱动出流式体验——说话过程中每隔 `partial_interval`（默认 0.6 秒）对当前句重解码一次给出临时结果，句末静音触发定稿。因此延迟约为 0.6 秒级，而非逐字上屏的几十毫秒级。若需要后者，需换成真流式模型（如 zipformer），但会失去粤语支持。

## 环境要求

| 项目 | 要求 | 本机实测 |
| --- | --- | --- |
| Python | `>=3.11.4,<3.13` | 3.11.13（uv 托管） |
| 包管理 | [uv](https://docs.astral.sh/uv/) | 0.11.30 |
| ffmpeg | 需在 PATH 中（解码 mp3/m4a/视频、重采样） | 7.0.1 |
| 硬件 | 纯 CPU 即可，无需 GPU | 无 NVIDIA GPU |
| 磁盘 | 模型约 240 MB | — |
| 麦克风（可选） | `sounddevice`，用于实时识别 | 已装 |

## 快速开始

```bash
# 1. 安装依赖（含麦克风支持）
uv sync --extra mic

# 2. 下载模型（约 155 MB 压缩包，解压后 240 MB；仅需一次）
uv run vsasr download

# 3. 转写音频，字幕打到标准输出
uv run vsasr transcribe data/samples/yue.wav -l yue

# 4. 导出多种格式
uv run vsasr transcribe meeting.mp3 -o meeting.srt -o meeting.json

# 5. 麦克风实时识别，结束后存字幕
uv run vsasr live -l zh -o live.srt
```

模型默认下载到 `~/.cache/voice-small-asr/models`，多个项目共享同一份。可用环境变量 `VSASR_MODEL_DIR` 或 `--model-dir` 改到别处。

下载按三个源依次尝试，任一成功即止：GitHub 直连 → `ghfast.top` → `gh-proxy.com`（后两个是 GitHub Release 的公共代理镜像，国内直连常超时）。某个源超时、返回错误码或给出截断内容时会自动换下一个，全部失败才报错。Flutter 端用同一份源列表、同样的顺序。

## 命令行

```
vsasr download                 预先下载模型
vsasr transcribe <音频>        转写文件
vsasr live                     麦克风实时识别
vsasr devices                  列出录音设备
```

### transcribe

```bash
uv run vsasr transcribe input.m4a \
    -l yue \                   # 语言：auto/zh/en/ja/ko/yue，默认 auto
    -o out.srt -o out.json \   # 输出文件，可重复；格式由扩展名决定
    -f srt \                   # 不指定 -o 时打到标准输出的格式
    -t 4                       # CPU 线程数
```

支持 ffmpeg 能解码的一切格式，包括视频文件（自动抽音轨）。

### live

```bash
uv run vsasr live -l zh --partial-interval 0.5 -o meeting.srt
```

终端里临时结果原地刷新、定稿结果换行留存；`Ctrl+C` 结束并写出字幕。用 `vsasr devices` 查设备号后用 `--device 6` 指定输入设备。`--partial-interval 0` 可关闭临时结果，只输出定稿句子。

## 集成到其他项目

公开 API 集中在包顶层，只有数据类与两个门面类，不暴露 sherpa-onnx 的任何类型：

```python
from voice_small_asr import (
    ASRConfig, VADConfig,            # 配置
    Transcriber,                     # 整段转写
    StreamingTranscriber,            # 流式转写
    Segment, Word, TranscriptionResult,   # 结果数据类（全部 dataclass）
    subtitles, audio, models,        # 字幕导出 / 音频工具 / 模型管理
    transcribe,                      # 一行式便捷函数
)
```

### 整段转写

```python
from voice_small_asr import ASRConfig, Transcriber, subtitles

# 构造一次、复用多次：模型加载才是耗时项（约 1~2 秒），识别本身很快
transcriber = Transcriber(ASRConfig(language="yue"))

result = transcriber.transcribe("meeting.m4a")
print(result.text)                  # 整段文本
print(result.duration)              # 音频时长（秒）

for seg in result:
    print(seg.index, seg.start, seg.end, seg.language, seg.text)
    for word in seg.words:          # token 级时间戳
        print("   ", word.text, word.start, word.end)

subtitles.write(result, "meeting.srt")     # 格式由扩展名推断
payload = result.to_dict()                 # 可直接 JSON 序列化
```

也接受 numpy 数组（16 kHz、float32、单声道、范围 [-1, 1]）：

```python
import numpy as np
result = transcriber.transcribe(np.zeros(16000, dtype=np.float32))
```

### 流式转写

`accept()` 送入音频块，返回本次产生的段。按 `is_final` 区分：`True` 是定稿句（时间戳可靠，可写字幕），`False` 是临时结果（用于即时上屏，随后会被同句的定稿结果替换）。

```python
from voice_small_asr import ASRConfig, StreamingTranscriber, audio

streamer = StreamingTranscriber(ASRConfig(language="auto", partial_interval=0.5))

for chunk in audio.iter_microphone():          # 或任何 16 kHz float32 音频块来源
    for seg in streamer.accept(chunk):
        if seg.is_final:
            print(f"[{seg.start:.2f}s] {seg.text}")      # 追加
        else:
            print(f"\r{seg.text} …", end="")             # 覆盖上一次临时结果

for seg in streamer.flush():                   # 流结束时取尾部未定稿内容
    print(f"[{seg.start:.2f}s] {seg.text}")
```

音频来源可以是任何东西——WebSocket 帧、队列、文件回放，只要是 16 kHz float32 单声道数组。生成器形式的封装：

```python
from voice_small_asr import stream, stream_file, stream_microphone

for seg in stream_file("a.wav", realtime=True):   # realtime 按真实速度节流
    ...
for seg in stream(my_chunk_iterator()):           # 自定义来源
    ...
```

### 服务端模式

见 `examples/service_integration.py`：启动时构造一次，生产环境用 `allow_download=False` 让缺模型立刻失败，识别器加锁串行化（需要更高并发时改为每线程一个实例）。

```python
from voice_small_asr import ASRConfig, Transcriber

transcriber = Transcriber(
    ASRConfig(language="auto", model_dir="/opt/models/vsasr", num_threads=4),
    allow_download=False,          # 生产环境不隐式联网
)
```

### 可运行示例

```bash
uv run python examples/transcribe_file.py data/samples/yue.wav yue
uv run python examples/live_microphone.py zh
uv run python examples/service_integration.py data/samples/zh.wav
```

## 离线部署

模型只在首次运行时下载。要部署到无网机器：

```bash
# 联网机器上准备好模型
uv run vsasr download --model-dir ./models-bundle

# 把 models-bundle/ 整个拷到目标机，然后指定目录
export VSASR_MODEL_DIR=/opt/models-bundle       # Windows: $env:VSASR_MODEL_DIR="..."
uv run vsasr transcribe input.wav
```

目录结构固定为：

```
<模型目录>/
├── silero_vad.onnx
└── sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/
    ├── model.int8.onnx
    └── tokens.txt
```

代码里用 `models.is_ready()` 检查、`allow_download=False` 强制离线。

## 实测性能

本机（无 GPU，CPU 推理，3 线程，int8 模型）转写模型自带示例音频：

| 音频 | 时长 | 耗时 | RTF | 识别结果 |
| --- | --- | --- | --- | --- |
| zh.wav | 5.59s | 0.20s | 0.035 | 开饭时间早上9点至下午5点。 |
| en.wav | 7.15s | 0.24s | 0.033 | The tribal chieftain called for the boy. / And presented him with 50 pieces of code. |
| ja.wav | 7.20s | 0.23s | 0.032 | うちの中学は弁当制で持っていきない場合は五十円の学校販売のパンを買う。 |
| yue.wav | 5.15s | 0.14s | 0.028 | 呢几个字都表达唔到，我想讲嘅意思。 |

RTF ≈ 0.03 表示比实时快约 30 倍，单核 CPU 也足以支撑实时流式。粤语一行可作为选型验证：`唔` `嘅` 均被保留。

## 目录结构

```
VoiceSmallASR/
├── src/voice_small_asr/
│   ├── __init__.py       公开 API 门面
│   ├── config.py         ASRConfig / VADConfig / 模型目录解析
│   ├── models.py         模型下载、解压、缓存与就绪检查
│   ├── audio.py          音频加载、重采样、分块、麦克风采集
│   ├── vad.py            silero-vad 封装与语音段迭代
│   ├── engine.py         SenseVoice 解码 + 整段转写（Transcriber）
│   ├── streaming.py      VAD 驱动的流式识别（StreamingTranscriber）
│   ├── segments.py       Word / Segment / TranscriptionResult
│   ├── subtitles.py      SRT / VTT / JSON / TXT 导出
│   └── cli.py            命令行
├── app/                  Flutter 三端客户端（Windows / macOS / Android）
├── examples/             可运行集成示例
├── tests/                单元测试 + 端到端集成测试
├── data/samples/         示例音频（不入库）
├── models/               预留的本地模型目录（不入库）
└── DEVELOPMENT_PLAN.md   后续开发计划与踩坑记录
```

## 图形界面（Flutter 三端）

`app/` 是同一套能力的图形界面，覆盖 Windows / macOS / Android，用 pub.dev 上的
[`sherpa_onnx`](https://pub.dev/packages/sherpa_onnx) 包，与 Python 端**同版本（1.13.5）、同模型**，
因此识别结果一致，Python 端可作为对照基准。

当前进度：**M1（文件转写 + 字幕导出）、M2（麦克风实时字幕）、M3（视频播放 + 字幕叠加）、M5（字幕校对编辑）与 M11（项目管理 + 外部字幕导入）已完成，M4 翻译基础、批量流程、双语导出、第三方 API provider、文件/实时字幕/视频字幕翻译工作流已接入，M8 发布质量基线代码已落地** —— 引擎层、音频解码、
后台识别 isolate、流式识别、视频播放与字幕联动都已接入，M6 首期设置页、模型管理与离线模式已接入，M9 已支持目标语言持久化、API 连接测试、第三方数据发送提示和实时字幕单条重试，M11 已完成项目文件数据层、首页保存/打开、最近项目、Android SAF、自动保存、异常恢复、媒体缺失重新定位、SRT/VTT/JSON 导入和视频外部字幕加载，M12 已接入多文件批量转写、批量翻译、安全导出、本地文本缓存与队列恢复，M13 已加入字幕批量时间偏移、搜索替换、阅读速度检查、翻译术语表、服务商预设、播放器字幕样式、视频配套字幕导出、桌面与 Android 硬字幕视频编码、文件转写性能诊断、批量/实时性能汇总、持续性能历史以及手工和自动说话人分离，`flutter test` 234 项、Python 测试 107 项、macOS 端到端 7 项和 Android API 35 模拟器端到端 7 项通过；模拟器粤语识别 RTF 为 0.027，Android API 35 模拟器硬字幕真实编码通过。自动分离和硬字幕的真实验收脚本已加入；当前 Android 真机性能、Windows 用户桌面和桌面带 libass 的 FFmpeg 仍待验收。
macOS 端已端到端验收：同一个 `yue.wav`，Flutter 端与 Python 端输出**逐字一致**
（`呢几个字都表达唔到，我想讲嘅意思。`），RTF 约 0.06；实时识别把三段素材拼成「三句话」喂进去，
每句都定稿且时间戳连续不重叠。
后续计划包括 Android 真机性能和 Windows 用户桌面运行验证；个人使用不要求执行真实第三方 API 网络验收。
当前已可通过 `scripts/build_macos_unsigned.sh` 生成不含模型的 macOS Release `.app`/`.dmg`，并已在本机成功构建 Android release APK/AAB；个人使用时未提供签名变量即可使用 Android debug signing 构建 APK，正式发布/商店签名不在本项目范围内。Android signing 配置仍支持 `VSASR_ANDROID_KEYSTORE_FILE`、`VSASR_ANDROID_KEY_ALIAS`、`VSASR_ANDROID_KEYSTORE_PASSWORD` 和 `VSASR_ANDROID_KEY_PASSWORD` 四个环境变量，并已用临时 keystore 验证可选的外部签名链路。
macOS 无签名包可以完成个人使用所需的编译与打包；如果 `flutter_secure_storage` 因 Keychain Sharing 不可用，应用会把 API Key 仅保存在当前会话内，退出后需要重新输入，不写入普通配置或明文文件。
第三方 API provider 和应用内翻译流程已接入，但个人使用可不配置 API Key；设置页支持翻译术语表（每行 `原词=译词`）和服务商预设，预设保存 endpoint、模型、目标语言和术语表组合但不保存 API Key；术语表会应用到文件、实时、视频和批量翻译，变化会隔离批量缓存；实时字幕页可打开“实时翻译”，首次使用前会提示字幕将发送到第三方服务，同一场录音会复用 provider，停止时不会逐条等待已排队请求，失败字幕可单条重试；视频播放页可点击“翻译字幕”，译文会显示在视频叠加层和字幕列表中，并可调整字幕样式、导出视频配套字幕文件；桌面视频页通过本机 FFmpeg 生成硬字幕 MP4，需使用包含 `libass`/`ass` 滤镜的 FFmpeg，并可用 `VSASR_FFMPEG_PATH` 指定路径；Android 视频页通过系统 MediaCodec/OpenGL 生成硬字幕 MP4，支持 AAC 音轨直通和 Android SAF 输出，iOS 暂不支持。真实网络验收仅在以后需要验证在线翻译时使用，密钥不会写入仓库。
Windows Release 与 Inno Setup 安装包已由 `.github/workflows/windows-build.yml` 在 Windows runner 上构建通过，CI 同时检查运行时 DLL 和模型文件排除，并通过无模型桌面 smoke 验证 AAC 解码与 MP4 播放；手动 `run_full_e2e=true` 的完整模型 e2e 已在 run `31919855391` 通过 7 项测试，用户桌面验证仍待完成。
`.github/workflows/release.yml` 已完成三端 GitHub Release：`v1.0.1` 已在云端生成 Android APK/AAB、Windows 未签名安装包和 macOS 未签名 DMG/APP 压缩包，可从 [GitHub Release](https://github.com/2653533859/VoiceSmallASR/releases/tag/v1.0.1) 下载；后续发布会先通过 Python/Flutter 质量门禁，检查三端产物不含模型，并上传 `SHA256SUMS.txt` 与 `BUILD_INFO.txt`。

音频解码上两端有意不同：Python 端调系统 ffmpeg，Flutter 端 wav 走纯 Dart 直读、压缩格式与视频交给平台原生解码（macOS 用 AVFoundation，Android 用 MediaCodec，Windows 用 Media Foundation）——`ffmpeg_kit_flutter` 已弃养且从不支持 Windows。macOS 那份已编译并端到端跑通；Android 的 Kotlin 已在 API 35 ARM64 模拟器端到端验证但尚未真机运行，Windows 的 C++ 已在 MSVC CI 编译并通过桌面 smoke 与完整模型 e2e，但用户桌面运行仍未验证。

```bash
# 国内建议先配 SDK 镜像：storage.googleapis.com 实测约 100 KB/s
export FLUTTER_STORAGE_BASE_URL=https://mirrors.cloud.tencent.com/flutter

cd app
flutter pub get
flutter analyze
flutter test                # 不需要模型、不需要设备
flutter build apk --release       # 需要 Android SDK/JDK
flutter build appbundle --release # 需要 Android SDK/JDK
flutter run -d macos        # 常规 Flutter 运行可能需要开发证书；个人使用可用无签名构建脚本
flutter run -d windows      # 需开启 Windows 开发者模式 + Visual Studio C++ 工具链
```

阶段划分、待决策事项、平台限制与踩坑记录见 [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md)；v1.0.2 之后的任务见 [NEXT_DEVELOPMENT_PLAN.md](NEXT_DEVELOPMENT_PLAN.md)。

## 已知限制与取舍

- **延迟不是逐字级**。临时结果约 0.6 秒刷新一次，定稿取决于句末静音（默认 0.35 秒）加推理时间。真正逐字流式需换模型，代价是失去粤语。
- **自动说话人分离已接入**。首页可在当前媒体上自动估计或指定说话人数，模型首次按需下载并校验，字幕段会得到 `SPEAKER_00` 等聚类标签，随后可在校对页改名；真实移动/桌面验收仍需相应设备和无签名可运行环境。
- **中英混说**时 `auto` 偶有语言判定抖动，已知场景建议显式指定语言。
- **标点依赖 ITN**（默认开启）。模型的 2025-09-09 版本不支持标点，因此本项目固定用 2024-07-17 版。
- **`sherpa-onnx` 与 `sherpa-onnx-core` 版本必须严格一致**，且不能省略 `sherpa-onnx-core`。缺少它时，扩展模块会退回加载 `C:\Windows\System32\onnxruntime.dll`（较旧），报 `requested API version [27] is not available` 后直接段错误。已在 `pyproject.toml` 中固定并注释。

## 开发

```bash
uv sync --extra mic          # 安装全部依赖
uv run ruff check .          # 静态检查
uv run ruff format .         # 格式化
uv run pytest                # 全部测试（107 项）
```

测试分两层：不依赖模型的单元测试（字幕、配置、数据结构、模型缓存、CLI）随时可跑；依赖模型的集成测试用模型包自带的多语种音频，模型缺失时自动跳过（未下载模型时为 87 passed / 18 skipped）。下载相关的测试用替身响应对象，不发真实网络请求。
