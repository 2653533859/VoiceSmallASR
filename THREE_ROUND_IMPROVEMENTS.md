# 三轮改进交付与验收

本记录对应 2026-09-05 三轮改进代码。既有发布版本仍为 v1.0.4；本次同步源码与文档，不创建版本标签或发布安装包。
历史里程碑见 `NEXT_DEVELOPMENT_PLAN.md`；当前新增行为与剩余验证以本文为准。

## 第一轮：稳定工作台与任务边界

- Studio 增加撤销、重做、搜索替换原文、阅读速度检查及点击问题字幕回听；复用现有编辑控制器。
- 普通状态通知不重建编辑历史，外部结果/项目替换使迟到翻译失效；繁忙时禁止内联编辑。
- worker 的冷启动占用容量，异常实例通过 discard 移出池；销毁中的实例也纳入容量。
- 实时录音显式记录待处理音频，默认最多保留 5 秒；超限时提示并停止，不静默跳过音频继续伪装成功。
- 录音停止、识别确认、会话完成和设备释放有超时与最终清理。旧会话返回不能修改新会话状态。
- `.github/workflows/quality.yml` 在 main push、PR 和手工触发时执行 Python Ruff/pytest 与 Flutter analyze/test。Release 的原质量门禁继续保留。推送后触发云端检查，实际结果以对应提交的 Actions 记录为准。

## 第二轮：长音频资源控制

- 默认文件/批量转写使用已有流式会话与分块解码管线。只有显式注入不支持分块接口的解码器，才保留旧整段路径。
- WAV 按文件窗口读取、混声道和连续重采样，按绝对采样位置续接；原生压缩格式复用既有连续解码协议。
- 每次仅在上一块识别确认后读取下一块；取消及识别流错误会中止后续读取，失败实例不回池复用。
- 文件报告增加 `peak_rss_bytes`、`first_final_ms`、`chunk_count`；实时报告增加 `peak_pending_audio_ms`、`max_accept_latency_ms`、`overload_count`。
- `peak_rss_bytes` 是整个进程在检查点采样的峰值，不是单模型大小，也不是操作系统连续采样的绝对峰值。`first_final_ms` 从取得任务容量开始，包含模型准备，不包含排队。文件 RTF 使用解码与识别耗时，不包含模型准备。
- 并发默认值暂时保持既有手机 2、桌面 4；支持通过现有调度器容量注入作对照。当前没有低内存真机数据，不把短样本结果当作设置最低内存或提升默认并发的依据。
- 自动说话人分离仍使用原有整段解码；本轮没有声称所有功能均实现有界内存。

## 第三轮：字幕质量基准

- `scripts/evaluate_asr.py` 支持已有预测 JSON 与本地模型评测，无新增依赖，不隐式下载模型。
- 记录 CER/WER、时间重叠意义下的漏段与边界偏差、语料/模型/配置标识和 SHA-256。
- 固定语料规划与人工复核规范位于 [`data/benchmark/README.md`](data/benchmark/README.md)，覆盖粤语、混合语言、噪声、长停顿和韩语。
- 当前 7 条是待采集条目，未冒充真实人工语料。缺素材或人工参考的评测报告为 `incomplete`，退出码 2；`complete` 也只表示指标计算完成，质量门禁仍为 `not_evaluated`。
- 首轮真实语料完成后才制定可比较的质量阈值；波形编辑、局部重识别继续作为后续增量功能，本轮没有换模型或改推理架构。

## 可复现验证

本轮验证：Python 117 项测试、Ruff、Flutter 336 项测试及全项目 `flutter analyze` 通过。macOS Debug 构建、真实粤语文件生产管线与双 worker 资源入口 smoke 通过。新增工作流已做本地 YAML 语法检查，尚无云端运行结果。

从仓库根目录执行：

```sh
.venv/bin/python -m pytest -q -rs
.venv/bin/ruff check .
cd app
flutter analyze --no-pub
flutter test --no-pub
```

真实模型生产管线（macOS，需已有模型及其 `test_wavs/yue.wav`）：

```sh
cd app
VSASR_MODEL_DIR=/path/to/models flutter test integration_test/e2e_test.dart -d macos --no-pub --plain-name '文件分块生产管线'
```

真实长音频资源对照（分别以 workers=1、2、4 启动独立测试进程，输出不同报告；多 worker 同时处理同一素材用于测量资源成本）：

```sh
cd app
VSASR_MODEL_DIR=/path/to/models flutter test integration_test/file_stream_acceptance_test.dart -d macos --no-pub \
  --dart-define=VSASR_DEVICE_TEST_AUDIO=/path/to/long-speech.wav \
  --dart-define=VSASR_DEVICE_WORKERS=1 \
  --dart-define=VSASR_DEVICE_TEST_REPORT=/path/to/report-workers-1.json
```

此入口每 500 ms 采样进程 RSS，保存每任务报告，不验证识别准确率。必须显式提供素材和报告路径，缺少时测试失败，不以跳过冒充验收成功。

2026-09-05 本机 macOS Debug 构建及以上生产管线测试通过：粤语结果与已有固定基准逐字一致，82,368 个采样点、5.148 秒、1 段字幕、1 个音频块。该次解码约 16 ms、识别约 318 ms、模型准备约 3,314 ms，进程采样峰值 RSS 为 786,923,520 bytes。它验证真实模型接线与诊断，不代表真实长语音或低内存设备性能。

同日以相同 5.148 秒样本跑双 worker 资源入口 smoke：两份任务报告均完成，共记录 9 个定时/边界 RSS 样本，采样峰值 1,199,308,800 bytes，报告 `quality_verified=false`。这确认并发和资源报告入口可用，也表明多个模型实例的实际进程成本需要测量；不能据此宣称长音频或移动设备验收通过。

WAV 单测覆盖 7 种编码 × 4 种采样率与原解码逐样本一致、跨窗口重采样、断点与尾块；128 MiB 稀疏 WAV 首块读取低于 64 KiB。稀疏 WAV 仅验证 I/O 边界，不是语音质量样本。

## 仍需真实环境完成

1. 按 [`M20_DEVICE_ACCEPTANCE.md`](M20_DEVICE_ACCEPTANCE.md) 完成 Android 真机、Windows 用户桌面和 macOS 真实睡眠/唤醒验收。
2. 对真实含语音的 1～2 小时媒体记录持续字幕生成、取消延迟、内存随时间变化及并发 1/2/4 的对照。现有视频断点恢复继续复用；普通文件目前保留失败前定稿结果，但不宣称已具备磁盘断点续接。
3. 按语料规范采集并人工复核，运行固定质量基准。不要把合成测试通过或关键词匹配当作真实质量提升。
4. 推送后检查新 CI 的云端结果；三端新安装包验收仍须在后续明确发布任务中完成。
