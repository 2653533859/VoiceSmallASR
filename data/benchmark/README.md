# 固定人工语料评测

当前只有评测工具和 **7 条待采集计划**，没有真实音频、人工转写或质量结论。`manifest.example.json` 不能作为验收通过证据。单元测试使用合成数据，只验证评分逻辑。该最小集用于发现回归，不代表语言整体准确率。

## 采集及冻结

1. 使用获得授权的真人录音；每条 15–45 秒、至少两句。粤语清晰、粤英混合、普通话英语混合、粤语噪声、粤语长停顿（至少 5 秒静音）、韩语清晰、韩语噪声各一条。噪声条目记录噪声来源和录音环境；未知 SNR 不填估计值。建议粤语和韩语至少各两名说话人。
2. 音频放在 manifest 相对路径 `audio/`，保留原始文件；记录来源、授权、匿名说话人 ID、时长、采样率、环境。不要提交含敏感信息的录音。
3. 人工逐句听写原话，保留粤语用字和切换语言；韩语由懂韩语的人复核。第二人复核文本、起止时间和不可辨认区间。不能以模型输出直接充当参考。不可辨认条目在确定参考前保持 planned；不要静默删除难句。
4. 填入 `reference_text`（全文字符串）、`reference_segments`（可选、推荐所有条目提供）、音频 SHA256、标注人/复核人匿名 ID，将 `annotation_status` 改为 `human_verified`。每段格式为 `{"start": 0.5, "end": 2.8, "text": "人工听写原话"}`，单位秒，相对音频开头，按起点排序。全文应与段文本一致，边界取真实发声起止，避免按字幕显示时间标注。
5. 保存为 `manifest.json` 并将 corpus_id 改为固定版本号；修改音频或参考必须升版，保留旧版。不根据当前模型结果修改参考。`shasum -a 256 audio/文件.wav` 可计算文件哈希。

## 运行

在项目根目录（已安装项目的 `.venv`）：

```sh
.venv/bin/python scripts/evaluate_asr.py data/benchmark/manifest.json --predictions /tmp/predictions.json --output /tmp/asr-report.json
.venv/bin/python scripts/evaluate_asr.py data/benchmark/manifest.json --run-model --config /tmp/asr-config.json --output /tmp/asr-report.json
```

模型配置 JSON 示例：`{"language":"yue","num_threads":4,"use_itn":true,"vad":{"min_silence_duration":0.35}}`。混合语言整套评估建议 `language=auto`，额外运行 `yue`/`ko` 对照时另存报告并仅比较适用条目。模型模式使用本地已有权重，`allow_download=False`，不会下载；模型缺失会报错。配置可指定 `model_dir`。模型模式额外写出 `/tmp/asr-report.predictions.json`，记录模型文件哈希和完整配置，便于离线重算。

已有预测模式不需要模型权重，但使用项目 Python 环境。预测格式如下（内容仅为格式示意，须替换为实际输出与哈希）：

```json
{
  "model_id": "实际模型版本或权重标识",
  "config": {"language": "auto", "use_itn": true},
  "items": [
    {"id": "yue-clean-001", "audio_sha256": "与manifest一致的完整SHA256", "text": "实际预测文本", "segments": [{"start": 0.5, "end": 2.8, "text": "实际预测文本"}]}
  ]
}
```

`text` 和 `segments` 来自最终预测；导入实时结果时先排除 partial。有参考段时必须提供预测 `segments`，完全漏识别使用空数组。每条预测必须绑定实际音频哈希。未知 ID 或重复 ID 报错。

## 解释报告

- CER：NFKC、casefold、删除 Unicode 标点后，去空白逐字符计算 Levenshtein 距离 / 参考字符数。不做繁简转换、数字读法转换或同义改写。
- WER：相同规范化，按空白分词。中文/粤语主要看 CER；WER 不使用中文分词器，不能与采用其他分词规则的结果直接比较。韩语 WER 按空格词计算。
- 聚合 CER/WER 按全部已评分条目的参考单位数加权。没有参考单位时 rate 为 null，保留插入错误计数；错误率可能大于 1。
- 漏段是没有任何非空预测段与参考段形成正时间重叠的参考段。边界偏差是所有重叠预测段包络与参考段起止的绝对误差均值，仅对匹配段计算。它衡量时间覆盖，不是语义对齐；时间错位可能被算作漏段，过长预测会覆盖多个参考段，需结合 CER 和逐条检查。无参考段不生成时间指标。
- 缺少音频、哈希不匹配、人工参考或预测时，条目标为 blocked，报告为 incomplete，退出码 2；这些条目不参与聚合。不要把部分语料的低 CER 当成全套通过。完整计算退出码 0 只表示评测完成，`quality_gate=not_evaluated`，不代表质量达标。首轮真实评测完成后才可结合产品要求制定验收阈值。
- 报告包含 corpus_id、manifest SHA256、音频 SHA256、模型标识、配置及每条指标；真实模型模式含模型文件 SHA256。预测模式的模型/配置元数据由提供方负责真实性。

可执行计划检查（预期 incomplete、0/7、退出码 2；无需模型）：

```sh
.venv/bin/python scripts/evaluate_asr.py data/benchmark/manifest.example.json --run-model --output /tmp/asr-planned-report.json
```
