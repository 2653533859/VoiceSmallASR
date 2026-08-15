/// SenseVoice 解码 + VAD 分段的整段转写。
/// 对应 Python 端 `voice_small_asr/engine.py` 与 `vad.py`。
///
/// sherpa_onnx 的原生对象只在本文件出现，对外一律返回 [Segment]。
/// 注意 Dart 绑定需要手动 `free()`，所有持有原生指针的对象都在
/// [AsrEngine.dispose] / [VadSession.dispose] 里释放。
library;

import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';

/// SenseVoice 用 `<|zh|>` 这类标签承载语言/情感/事件元信息。
final RegExp _tagRe = RegExp(r'<\|([^|]*)\|>');

/// `'<|zh|>'` -> `'zh'`；非标签内容原样去空白返回。
String unwrapTag(String? value) {
  if (value == null || value.isEmpty) return '';
  final String text = value.trim();
  final RegExpMatch? matched = _tagRe.firstMatch(text);
  if (matched != null && matched.start == 0 && matched.end == text.length) {
    return matched.group(1) ?? '';
  }
  return text.replaceAll(_tagRe, '').trim();
}

/// 把 token 级时间戳换算到全局时间轴。
///
/// Dart 版 [so.OfflineRecognizerResult] 没有 `durations` 字段，
/// 因此 token 的结束时间取下一个 token 的起点，最后一个取段末。
List<Word> buildWords(so.OfflineRecognizerResult result, double offset, double limit) {
  final List<String> tokens = result.tokens;
  final List<double> starts = result.timestamps;
  final int count = tokens.length < starts.length ? tokens.length : starts.length;
  final List<Word> words = <Word>[];
  for (int i = 0; i < count; i++) {
    // 只去掉元信息标签；不能顺手 trim 掉纯空格 token —— SenseVoice
    // 把英文词间空格作为独立 token 输出，丢了会拼成 "with50"。
    final String token = tokens[i].replaceAll(_tagRe, '');
    if (token.isEmpty) continue;
    final double start = starts[i] < limit ? starts[i] : limit;
    double end = (i + 1 < count) ? starts[i + 1] : limit;
    if (end < start) end = start;
    if (end > limit) end = limit;
    words.add(Word(text: token, start: offset + start, end: offset + end));
  }
  return words;
}

/// VAD 会话：一路音频对应一个实例，用完必须 [dispose]。
class VadSession implements SpeechSegmenter {
  VadSession._(this._vad, this.config);

  factory VadSession.create(VadConfig config, String modelPath, {double bufferSeconds = 60.0}) {
    final so.VadModelConfig vadConfig = so.VadModelConfig(
      sileroVad: so.SileroVadModelConfig(
        model: modelPath,
        threshold: config.threshold,
        minSilenceDuration: config.minSilenceDuration,
        minSpeechDuration: config.minSpeechDuration,
        maxSpeechDuration: config.maxSpeechDuration,
        windowSize: config.windowSize,
      ),
      sampleRate: kSampleRate,
      numThreads: 1,
      provider: 'cpu',
    );
    return VadSession._(
      so.VoiceActivityDetector(config: vadConfig, bufferSizeInSeconds: bufferSeconds),
      config,
    );
  }

  final so.VoiceActivityDetector _vad;
  final VadConfig config;

  /// 是否正在说话（用于决定要不要出局部结果）。
  @override
  bool get isSpeaking => _vad.isDetected();

  /// 送入音频。按 `windowSize` 分批喂，与 silero-vad 的推理窗口对齐 ——
  /// 整段一次性喂会让段起点判定失准。
  @override
  void accept(Float32List samples) {
    final int window = config.windowSize;
    for (int offset = 0; offset < samples.length; offset += window) {
      final int end = (offset + window) < samples.length ? offset + window : samples.length;
      _vad.acceptWaveform(Float32List.sublistView(samples, offset, end));
    }
  }

  /// 取出所有已完成的语音段，`start` 为全局秒数。
  @override
  List<({Float32List samples, double start})> drain() {
    final List<({Float32List samples, double start})> out = <({Float32List samples, double start})>[];
    while (!_vad.isEmpty()) {
      final so.SpeechSegment segment = _vad.front();
      _vad.pop();
      if (segment.samples.isNotEmpty) {
        out.add((samples: segment.samples, start: segment.start / kSampleRate));
      }
    }
    return out;
  }

  /// 音频结束时调用，把尾部未定稿的语音段推入队列。
  @override
  void flush() => _vad.flush();

  @override
  void reset() => _vad.reset();

  @override
  void dispose() => _vad.free();
}
