/// VAD 驱动的流式（准实时）识别。对应 Python 端 `voice_small_asr/streaming.py`。
///
/// SenseVoice 是非流式模型，这里用 VAD 造出流式体验：
///
/// * VAD 判定一句说完 → 产出 `isFinal=true` 的定稿段（时间戳可靠，可写字幕）；
/// * 说话过程中每隔 `partialInterval` 秒对「当前这句」整句重解码一次，
///   产出 `isFinal=false`、`index=-1` 的局部段，供界面即时上屏，随后被定稿段替换。
///
/// 因此延迟是局部结果约 0.6 秒、定稿约「句末静音 + 推理时间」，不是逐字级。
///
/// 与 Python 端的唯一实现差异：Dart 绑定**没有** `currentSegment`，
/// 拿不到 VAD 内部正在攒的那句音频，只能自己维护缓冲区（见 [_absorb]）。
library;

import 'dart:typed_data';

import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';

/// 局部结果所需的最短音频长度（秒），太短的片段识别没有意义。
/// 与 Python 端 `MIN_PARTIAL_SECONDS` 一致。
const double kMinPartialSeconds = 0.35;

/// 句首回看时长（秒）。
///
/// VAD 要连续听到 [VadConfig.minSpeechDuration] 才认定「在说话」，此前的窗口
/// 已经喂进去了。不往回补这一段，局部结果就会缺开头几个字（定稿段不受影响 ——
/// 那是 VAD 自己吐出来的，它内部保留了完整的句子）。
const double kPartialLookbackSeconds = 0.5;

/// 单调时钟（秒）。抽成函数是为了让节流逻辑可测。
typedef MonotonicClock = double Function();

final Stopwatch _processClock = Stopwatch()..start();

double _defaultClock() => _processClock.elapsedMicroseconds / 1e6;

/// 端点检测的最小契约，由 `VadSession` 实现。
///
/// 抽出来是为了让 [StreamingTranscriber] 能在没有原生库的环境里被测试。
abstract interface class SpeechSegmenter {
  /// 是否正在说话。
  bool get isSpeaking;

  /// 送入音频（内部按 `windowSize` 分批）。
  void accept(Float32List samples);

  /// 取出所有已完成的语音段，`start` 为全局秒数。
  List<({Float32List samples, double start})> drain();

  /// 音频结束时调用，把尾部未定稿的语音段推入队列。
  void flush();

  void reset();

  void dispose();
}

/// 解码单段音频的最小契约，由 `AsrEngine` 实现。
abstract interface class SegmentDecoder {
  Segment decodeSamples(
    Float32List samples, {
    double offset,
    bool isFinal,
    int index,
  });
}

/// 一路实时识别会话。
///
/// [segments] 上先后出现同一句的局部段与定稿段，界面按 `isFinal` 决定覆盖还是追加。
abstract interface class LiveSession {
  Stream<Segment> get segments;

  /// 送入一块 16 kHz float32 单声道音频。
  void accept(Float32List chunk);

  /// 结束录音：取出尾部未定稿的内容，关流并释放资源。
  Future<void> finish();
}

/// 流式识别器。喂音频块，返回本次产生的段。
///
/// 不持有任何原生资源：VAD 与解码器都由外部注入，[dispose] 也不碰它们。
class StreamingTranscriber {
  StreamingTranscriber({
    required this.segmenter,
    required this.decoder,
    required this.config,
    this.clock = _defaultClock,
  });

  /// 端点检测器。生命周期由调用方管，[StreamingTranscriber] 不负责释放。
  final SpeechSegmenter segmenter;
  final SegmentDecoder decoder;
  final AsrConfig config;

  /// 节流用的单调时钟，测试可替换。
  final MonotonicClock clock;

  /// 当前这句的音频缓冲（Dart 绑定没有 `currentSegment`，只能自己攒）。
  final List<Float32List> _buffer = <Float32List>[];
  int _bufferLength = 0;
  double _bufferStart = 0.0;

  /// 尚未开口时的回看窗口，开口瞬间用它补上句首。
  final List<Float32List> _lookback = <Float32List>[];
  int _lookbackLength = 0;

  /// 已送入的采样总数，用于换算时间轴。
  int _fed = 0;
  int _finalCount = 0;
  double _lastPartial = 0.0;

  /// 已产出的定稿段数量。
  int get finalCount => _finalCount;

  /// 已送入的音频总时长（秒）。
  double get elapsed => _fed / kSampleRate;

  /// 送入一块音频，返回本次产生的段（定稿段在前，局部段在后）。
  List<Segment> accept(Float32List chunk) {
    // 按窗口逐块喂：整段一次性喂会让段起点判定失准（Python 端同样如此），
    // 而且只有逐窗口喂才能捕捉到「开口」的那一刻，进而维护局部缓冲。
    final int window = config.vad.windowSize;
    for (int offset = 0; offset < chunk.length; offset += window) {
      final int end = (offset + window) < chunk.length ? offset + window : chunk.length;
      final Float32List view = Float32List.sublistView(chunk, offset, end);
      segmenter.accept(view);
      _absorb(view);
      _fed += view.length;
    }

    final List<Segment> produced = _takeFinals();
    final Segment? partial = _makePartial();
    if (partial != null) produced.add(partial);
    return produced;
  }

  /// 音频结束时调用，取出尾部未定稿的语音段。
  List<Segment> flush() {
    segmenter.flush();
    return _takeFinals();
  }

  /// 清空内部状态，开始新一路音频。
  void reset() {
    segmenter.reset();
    _clearBuffer();
    _lookback.clear();
    _lookbackLength = 0;
    _fed = 0;
    _finalCount = 0;
    _lastPartial = 0.0;
  }

  /// 维护「当前这句」的缓冲区。必须在 [SpeechSegmenter.accept] 之后调用 ——
  /// [SpeechSegmenter.isSpeaking] 要把刚喂进去的这一窗口也算上。
  void _absorb(Float32List view) {
    if (segmenter.isSpeaking) {
      if (_buffer.isEmpty) {
        // 开口的瞬间：把回看窗口一并算进来，否则局部结果缺开头。
        _bufferStart = (_fed - _lookbackLength) / kSampleRate;
        _buffer.addAll(_lookback);
        _bufferLength += _lookbackLength;
        _lookback.clear();
        _lookbackLength = 0;
      }
      _buffer.add(view);
      _bufferLength += view.length;
      return;
    }
    // 没在说话：只留最近一小段作回看，其余丢掉。
    _lookback.add(view);
    _lookbackLength += view.length;
    final int limit = (kPartialLookbackSeconds * kSampleRate).round();
    while (_lookbackLength > limit && _lookback.isNotEmpty) {
      _lookbackLength -= _lookback.removeAt(0).length;
    }
  }

  List<Segment> _takeFinals() {
    final List<Segment> finals = <Segment>[];
    for (final ({Float32List samples, double start}) speech in segmenter.drain()) {
      final Segment segment = decoder.decodeSamples(
        speech.samples,
        offset: speech.start,
        isFinal: true,
        index: _finalCount,
      );
      // 这句已经定稿，正在攒的缓冲作废；节流也重置，下一句可以立刻出局部结果。
      _clearBuffer();
      _lastPartial = 0.0;
      if (segment.text.isEmpty) continue;
      _finalCount++;
      finals.add(segment);
    }
    return finals;
  }

  Segment? _makePartial() {
    final double interval = config.partialInterval;
    if (interval <= 0 || !segmenter.isSpeaking) return null;
    if (_lastPartial > 0 && clock() - _lastPartial < interval) return null;
    if (_bufferLength < kMinPartialSeconds * kSampleRate) return null;

    final Segment segment = decoder.decodeSamples(
      _flattenBuffer(),
      offset: _bufferStart,
      isFinal: false,
    );
    // 解码之后才记时刻：局部解码要重跑整句，在弱 CPU 上可能比 partialInterval
    // 还慢；用解码前的时刻会让节流条件立刻再次满足，于是每块音频都触发一次
    // 重解码，把 CPU 吃满并拖慢定稿。Python 端同一处有相同注释。
    _lastPartial = clock();
    return segment.text.isEmpty ? null : segment;
  }

  Float32List _flattenBuffer() {
    final Float32List out = Float32List(_bufferLength);
    int offset = 0;
    for (final Float32List part in _buffer) {
      out.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return out;
  }

  void _clearBuffer() {
    _buffer.clear();
    _bufferLength = 0;
    _bufferStart = 0.0;
  }
}
