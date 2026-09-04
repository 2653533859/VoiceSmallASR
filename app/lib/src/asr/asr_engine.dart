/// 识别引擎门面：模型加载、整段转写、实时识别。
/// 对应 Python 端 `voice_small_asr/engine.py` 的 `Recognizer` 与 `Transcriber`。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';
import 'package:vsasr_app/src/asr/vad_session.dart';

/// 整段转写进度：[done] / [total] 为已处理与总采样数。
typedef TranscribeProgress = void Function(int done, int total);

/// 转写能力的最小契约。
///
/// 抽出来为了两件事：`TranscriptionWorker` 可以在后台 isolate 里换成替身，
/// 界面层也可以在没有原生库的环境里注入进程内替身 —— 于是整条链路都能测。
abstract interface class Transcriber {
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  });

  /// 开一路实时识别会话（麦克风）。同一时刻只应存在一路 ——
  /// 同一个识别器不能并发使用。
  Future<LiveSession> startLive();

  Future<void> dispose();
}

/// 识别引擎。构造一次、复用多次：模型加载要一到两秒，识别本身很快。
///
/// 用完必须调用 [dispose] 释放原生资源。长音频请通过
/// `TranscriptionWorker` 放到后台 isolate，别直接在 UI isolate 上跑。
class AsrEngine implements Transcriber, SegmentDecoder {
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

    final String effectiveProvider = _resolveProvider(cfg.provider);

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
          provider: effectiveProvider,
          debug: false,
        ),
      ),
    );
    return AsrEngine._(recognizer, paths, cfg);
  }

  static String _resolveProvider(String requested) {
    if (requested != 'auto') return requested;

    if (Platform.isAndroid) {
      // Android 8.1+ (API 27) 支持 NNAPI。
      // 注意：某些低端机的 NNAPI 实现可能比 CPU 还慢，
      // 但对于 SenseVoice 这种模型，通常 NPU 加速效果显著。
      return 'nnapi';
    } else if (Platform.isMacOS) {
      // Apple Silicon 设备上 CoreML 效果极佳。
      return 'coreml';
    }

    return 'cpu';
  }

  /// 解码单段音频。[offset] 是该段在整条音频里的起始秒数。
  @override
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
  @override
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
        final int end = (offset + chunk) < samples.length
            ? offset + chunk
            : samples.length;
        vad.accept(Float32List.sublistView(samples, offset, end));
        for (final ({Float32List samples, double start}) speech
            in vad.drain()) {
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

  /// 开一路实时识别：新建一个 VAD 会话，解码复用本引擎。
  @override
  Future<LiveSession> startLive() async {
    _ensureAlive();
    final VadSession vad = VadSession.create(config.vad, paths.vadModel);
    return _EngineLiveSession(
      StreamingTranscriber(segmenter: vad, decoder: this, config: config),
      vad,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _recognizer.free();
  }
}

/// 引擎自带的实时会话：同步解码，产出的段直接推进流里。
///
/// 解码是同步 FFI 调用，会占住当前 isolate —— 因此这个对象应当活在
/// `TranscriptionWorker` 的后台 isolate 里，而不是 UI isolate。
class _EngineLiveSession implements LiveSession {
  _EngineLiveSession(this._streamer, this._vad);

  final StreamingTranscriber _streamer;
  final VadSession _vad;
  final StreamController<Segment> _out = StreamController<Segment>.broadcast();
  bool _closed = false;

  @override
  Stream<Segment> get segments => _out.stream;

  @override
  Future<void> accept(Float32List chunk) async {
    if (_closed) return;
    for (final Segment segment in _streamer.accept(chunk)) {
      _out.add(segment);
    }
  }

  @override
  Future<void> finish() async {
    if (_closed) return;
    _closed = true;
    try {
      for (final Segment segment in _streamer.flush()) {
        _out.add(segment);
      }
    } finally {
      try {
        await _out.close();
      } finally {
        _vad.dispose();
      }
    }
  }
}
