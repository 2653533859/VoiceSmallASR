# M13 自动说话人分离真实模型验收

> 验收日期：2026-08-18

## 验收环境

- macOS 26.5.2，Apple Silicon（arm64）
- Flutter 3.47.0，Dart 3.13.0
- macOS Debug Runner：使用 ad-hoc 签名启动，不需要开发者证书
- 当前实现：pyannote segmentation + 3D-Speaker embedding + sherpa-onnx

## 验收素材与模型

- 官方音频：`0-four-speakers-zh.wav`
- 说话人数参数：`numClusters: 4`
- 分割模型：`sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx`
- 说话人向量模型：`3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx`
- 下载后的模型只放在临时目录，未提交到仓库

SHA-256 校验：

```text
sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488

sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx
d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d

3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx
1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b
```

## 执行命令

```bash
cd app
VSASR_SPEAKER_MODEL_DIR=/path/to/speaker-models \
VSASR_SPEAKER_TEST_AUDIO=/path/to/0-four-speakers-zh.wav \
flutter test integration_test/speaker_diarization_acceptance_test.dart -d macos
```

本次执行结果：

```text
00:12 +1: All tests passed!
```

验收脚本确认：模型路径完整、WAV 可解码为 16 kHz 输入、输出包含至少一个说话人时间段，且每个时间段的起止时间和说话人编号合法。该脚本验证的是推理链路和输出契约，不替代人工听辨准确率评估，也不保证聚类数量一定等于真实人数。

## 未覆盖范围

- Android 真机性能、内存和 Codec 差异仍待真实设备。
- Windows 用户桌面安装、启动和模型推理仍待用户环境。
- 真实第三方翻译 API 网络验收按个人使用范围继续跳过。
