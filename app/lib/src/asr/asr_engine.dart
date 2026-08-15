/// 识别引擎门面：模型加载、整段转写。
/// 对应 Python 端 `voice_small_asr/engine.py` 的 `Recognizer` 与 `Transcriber`。
library;

import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/vad_session.dart';

/// 整段转写进度：[done] / [total] 为已处理与总采样数。
typedef TranscribeProgress = void Function(int done, int total);

/// 识别引擎。构造一次、复用多次：模型加载要一到两秒，识别本身很快。
///
/// 用完必须调用 [dispose] 释放原生资源。
class AsrEngine {
  AsrEngine._(this._recognizer, this.paths, this.config);

  final so.OfflineRecognizer _recognizer;
  final ModelPaths paths;
  final AsrConfig config;
  bool _disposed = false;

  /// 创建引擎。模型缺失时按需下载（受 [allowDownload] 控制）。
  static Future<AsrEngine> create({
    AsrConfig? config,
    ModelManager? manager,
    bool allowDownload = true,
    ModelProgress? progress,
  }) async {
    final AsrConfig cfg = config ?? AsrConfig();
    final ModelManager models = manager ?? ModelManager();

    // 每个 isolate 都要单独初始化 FFI 绑定，否则后续调用会抛
    // "Please initialize sherpa-onnx first"。
    so.initBindings();

    final ModelPaths paths = await models.ensure(
      allowDownload: allowDownload,
      progress: progress,
    );

    final so.OfflineRecognizer recognizer = so.OfflineRecognizer(
      so.OfflineRecognizerConfig(
        model: so.OfflineModelConfig(
          senseVoice: so.OfflineSenseVoiceModelConfig(
            model: paths.asrModel,
            language: cfg.senseVoiceLanguage,
            useInverseTextNormalization: cfg.useItn,
          ),
          tokens: paths.tokens,
          numThreads: cfg.numThreads,
          provider: 'cpu',
          debug: false,
        ),
      ),
    );
    return AsrEngine._(recognizer, paths, cfg);
  }

  /// 解码单段音频。[offset] 是该段在整条音频里的起始秒数。
  Segment decodeSamples(
    Float32List samples, {
    double offset = 0.0,
    bool isFinal = true,
    int index = -1,
  }) {
    _ensureAlive();
    final so.OfflineStream stream = _recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: kSampleRate);
      _recognizer.decode(stream);
      final so.OfflineRecognizerResult result = _recognizer.getResult(stream);
      final double span = samples.length / kSampleRate;
      return Segment(
        text: result.text.trim(),
        start: offset,
        end: offset + span,
        words: buildWords(result, offset, span),
        language: unwrapTag(result.lang),
        isFinal: isFinal,
        index: index,
      );
    } finally {
      stream.free();
    }
  }

  /// 转写整条音频（16 kHz float32 单声道）。
  ///
  /// Dart 绑定没有批量 `decodeStreams`，因此逐段解码；调用方应放在
  /// isolate 或用 [onProgress] 驱动进度条，避免长音频卡住 UI。
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) async {
    _ensureAlive();
    final VadSession vad = VadSession.create(config.vad, paths.vadModel);
    final List<Segment> collected = <Segment>[];
    try {
      const int chunk = 16000; // 每次喂 1 秒，便于回报进度
      for (int offset = 0; offset < samples.length; offset += chunk) {
        final int end = (offset + chunk) < samples.length ? offset + chunk : samples.length;
        vad.accept(Float32List.sublistView(samples, offset, end));
        for (final ({Float32List samples, double start}) speech in vad.drain()) {
          collected.add(decodeSamples(speech.samples, offset: speech.start));
        }
        onProgress?.call(end, samples.length);
        // 让出事件循环，避免长音频把 UI 线程占满
        await Future<void>.delayed(Duration.zero);
      }
      vad.flush();
      for (final ({Float32List samples, double start}) speech in vad.drain()) {
        collected.add(decodeSamples(speech.samples, offset: speech.start));
      }
    } finally {
      vad.dispose();
    }

    final List<Segment> numbered = <Segment>[];
    for (final Segment segment in collected) {
      if (segment.text.isEmpty) continue;
      numbered.add(segment.copyWith(index: numbered.length));
    }
    return TranscriptionResult(
      segments: numbered,
      duration: samples.length / kSampleRate,
      language: config.language,
    );
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('AsrEngine 已释放，请重新 create()');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _recognizer.free();
  }
}
