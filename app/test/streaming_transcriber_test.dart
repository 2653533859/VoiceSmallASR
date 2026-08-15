/// 流式识别器的测试。VAD 与解码器都用替身，
/// 因此不需要模型、不需要原生库，`flutter test` 直接可跑。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';

void main() {
  test('音频按 windowSize 逐窗口喂给 VAD，而不是整块塞进去', () {
    final _FakeSegmenter vad = _FakeSegmenter();
    final StreamingTranscriber streamer = _build(vad, _FakeDecoder());

    streamer.accept(Float32List(1600));
    // 1600 = 512 + 512 + 512 + 64：整块一次性喂会让段起点判定失准
    expect(vad.windows, <int>[512, 512, 512, 64]);
    expect(streamer.elapsed, closeTo(0.1, 1e-9));
  });

  test('VAD 吐出的语音段被解码成定稿段，index 递增', () {
    final _FakeSegmenter vad = _FakeSegmenter();
    final _FakeDecoder decoder = _FakeDecoder();
    final StreamingTranscriber streamer = _build(vad, decoder);

    vad.queue.add((samples: Float32List(16000), start: 1.5));
    vad.queue.add((samples: Float32List(8000), start: 4.0));
    final List<Segment> produced = streamer.accept(Float32List(512));

    expect(produced, hasLength(2));
    expect(produced.every((Segment s) => s.isFinal), isTrue);
    expect(produced.map((Segment s) => s.index), <int>[0, 1]);
    // offset 原样透传：定稿段的时间戳来自 VAD，是可靠的
    expect(produced.map((Segment s) => s.start), <double>[1.5, 4.0]);
    expect(streamer.finalCount, 2);
  });

  test('空文本的定稿段被丢弃，也不占用 index', () {
    final _FakeSegmenter vad = _FakeSegmenter();
    final _FakeDecoder decoder = _FakeDecoder(texts: <String>['', '有内容']);
    final StreamingTranscriber streamer = _build(vad, decoder);

    vad.queue.add((samples: Float32List(16000), start: 0.0));
    vad.queue.add((samples: Float32List(16000), start: 2.0));
    final List<Segment> produced = streamer.accept(Float32List(512));

    expect(produced.map((Segment s) => s.text), <String>['有内容']);
    expect(produced.single.index, 0);
    expect(streamer.finalCount, 1);
  });

  test('说话中攒够音频就出局部结果：isFinal=false、index=-1', () {
    final _FakeSegmenter vad = _FakeSegmenter()..isSpeaking = true;
    final StreamingTranscriber streamer = _build(vad, _FakeDecoder());

    // 0.35 秒是 kMinPartialSeconds 的门槛，喂 0.4 秒
    final List<Segment> produced = streamer.accept(Float32List(6400));
    expect(produced, hasLength(1));
    expect(produced.single.isFinal, isFalse);
    expect(produced.single.index, -1);
  });

  test('音频不足 kMinPartialSeconds 时不出局部结果', () {
    final _FakeSegmenter vad = _FakeSegmenter()..isSpeaking = true;
    final _FakeDecoder decoder = _FakeDecoder();
    final StreamingTranscriber streamer = _build(vad, decoder);

    // 0.3 秒 < 0.35 秒
    expect(streamer.accept(Float32List(4800)), isEmpty);
    expect(decoder.calls, isEmpty);
  });

  test('局部结果按 partialInterval 节流，且节流时刻记在解码之后', () {
    final _FakeSegmenter vad = _FakeSegmenter()..isSpeaking = true;
    final _FakeDecoder decoder = _FakeDecoder();
    double now = 100.0;
    // 解码耗时 1 秒 —— 比 partialInterval(0.6) 还慢，模拟弱 CPU
    decoder.onDecode = () => now += 1.0;
    final StreamingTranscriber streamer = StreamingTranscriber(
      segmenter: vad,
      decoder: decoder,
      config: AsrConfig(partialInterval: 0.6),
      clock: () => now,
    );

    expect(streamer.accept(Float32List(6400)), hasLength(1));
    // 解码本身已经花掉 1 秒；若节流时刻记在解码之前，这一块会立刻再触发一次重解码
    now += 0.2;
    expect(streamer.accept(Float32List(1600)), isEmpty);
    now += 0.5; // 距上次解码结束已 0.7 秒 > 0.6
    expect(streamer.accept(Float32List(1600)), hasLength(1));
    expect(decoder.calls, hasLength(2));
  });

  test('partialInterval=0 时只出定稿段，不做局部重解码', () {
    final _FakeSegmenter vad = _FakeSegmenter()..isSpeaking = true;
    final _FakeDecoder decoder = _FakeDecoder();
    final StreamingTranscriber streamer = StreamingTranscriber(
      segmenter: vad,
      decoder: decoder,
      config: AsrConfig(partialInterval: 0),
    );

    expect(streamer.accept(Float32List(16000)), isEmpty);
    expect(decoder.calls, isEmpty);
  });

  test('局部结果会带上句首回看，不缺开头几个字', () {
    final _FakeSegmenter vad = _FakeSegmenter();
    final _FakeDecoder decoder = _FakeDecoder();
    final StreamingTranscriber streamer = _build(vad, decoder);

    // 静音期：0.5 秒回看窗口攒满（更早的会被丢掉）
    streamer.accept(Float32List(16000));
    // VAD 要连续听到 minSpeechDuration 才认定在说话，此前的窗口已经喂进去了
    vad.isSpeaking = true;
    streamer.accept(Float32List(6400));

    // 0.4 秒新音频之外还多带了一段回看。回看按整窗口丢弃，
    // 因此实际长度在「0.5 秒减一个窗口」到「0.5 秒」之间。
    final int lookback = decoder.calls.single.samples.length - 6400;
    const int limit = (kPartialLookbackSeconds * kSampleRate) ~/ 1;
    expect(lookback, lessThanOrEqualTo(limit));
    expect(lookback, greaterThan(limit - 512));
    // 起点相应往前挪了回看的时长：静音段结束于 1.0 秒
    expect(decoder.calls.single.offset, closeTo(1.0 - lookback / kSampleRate, 1e-9));
  });

  test('定稿之后缓冲作废，下一句立刻能出局部结果', () {
    final _FakeSegmenter vad = _FakeSegmenter()..isSpeaking = true;
    final _FakeDecoder decoder = _FakeDecoder();
    double now = 100.0;
    final StreamingTranscriber streamer = StreamingTranscriber(
      segmenter: vad,
      decoder: decoder,
      config: AsrConfig(),
      clock: () => now,
    );

    expect(streamer.accept(Float32List(6400)), hasLength(1)); // 局部
    // 这句定稿：缓冲清空、节流重置
    vad.queue.add((samples: Float32List(16000), start: 0.0));
    final List<Segment> produced = streamer.accept(Float32List(6400));
    expect(produced.map((Segment s) => s.isFinal), <bool>[true]);

    // 时钟没走，但节流已重置，只要新缓冲攒够就该出局部结果
    expect(streamer.accept(Float32List(6400)), hasLength(1));
    // 新一句的局部结果只含定稿后喂进去的音频，不会把上一句拖进来
    expect(decoder.calls.last.samples.length, 6400);
  });

  test('flush 把 VAD 尾部未定稿的语音段取出来', () {
    final _FakeSegmenter vad = _FakeSegmenter();
    final StreamingTranscriber streamer = _build(vad, _FakeDecoder());

    vad.tail.add((samples: Float32List(16000), start: 3.0));
    expect(streamer.accept(Float32List(512)), isEmpty);

    final List<Segment> produced = streamer.flush();
    expect(vad.flushed, isTrue);
    expect(produced.single.start, 3.0);
    expect(produced.single.isFinal, isTrue);
  });

  test('reset 清空所有状态，时间轴从头开始', () {
    final _FakeSegmenter vad = _FakeSegmenter();
    final StreamingTranscriber streamer = _build(vad, _FakeDecoder());

    vad.queue.add((samples: Float32List(16000), start: 0.0));
    streamer.accept(Float32List(16000));
    expect(streamer.finalCount, 1);

    streamer.reset();
    expect(vad.wasReset, isTrue);
    expect(streamer.finalCount, 0);
    expect(streamer.elapsed, 0.0);

    // index 也从 0 重新开始
    vad.queue.add((samples: Float32List(16000), start: 0.0));
    expect(streamer.accept(Float32List(512)).single.index, 0);
  });

  test('定稿会把同一块里正在攒的局部缓冲作废', () {
    final _FakeSegmenter vad = _FakeSegmenter()..isSpeaking = true;
    final StreamingTranscriber streamer = _build(vad, _FakeDecoder());

    vad.queue.add((samples: Float32List(16000), start: 0.0));
    // 这一块音频既够攒出局部结果，又让 VAD 吐出了定稿：
    // 定稿已经覆盖这段音频，再补一条局部结果只会让界面闪一下重复内容
    final List<Segment> produced = streamer.accept(Float32List(16000));
    expect(produced.map((Segment s) => s.isFinal), <bool>[true]);
  });
}

StreamingTranscriber _build(SpeechSegmenter vad, SegmentDecoder decoder) =>
    StreamingTranscriber(segmenter: vad, decoder: decoder, config: AsrConfig());

/// 假 VAD：说话状态与吐段时机都由测试直接摆布。
class _FakeSegmenter implements SpeechSegmenter {
  @override
  bool isSpeaking = false;

  /// 每个窗口的长度，用来验证是逐窗口喂的。
  final List<int> windows = <int>[];

  /// 下一次 [drain] 要吐出来的语音段。
  final List<({Float32List samples, double start})> queue =
      <({Float32List samples, double start})>[];

  /// [flush] 时才吐出来的尾段。
  final List<({Float32List samples, double start})> tail =
      <({Float32List samples, double start})>[];

  bool flushed = false;
  bool wasReset = false;
  bool disposed = false;

  @override
  void accept(Float32List samples) => windows.add(samples.length);

  @override
  List<({Float32List samples, double start})> drain() {
    final List<({Float32List samples, double start})> out = queue.toList();
    queue.clear();
    return out;
  }

  @override
  void flush() {
    flushed = true;
    queue.addAll(tail);
    tail.clear();
  }

  @override
  void reset() {
    wasReset = true;
    windows.clear();
    queue.clear();
    isSpeaking = false;
  }

  @override
  void dispose() => disposed = true;
}

/// 假解码器：记下每次调用的入参，文本可由测试指定。
class _FakeDecoder implements SegmentDecoder {
  _FakeDecoder({this.texts = const <String>[]});

  /// 按调用顺序取用的文本；用完或未提供时回退到默认值。
  final List<String> texts;

  /// 每次解码后执行，用来模拟「解码本身很慢」。
  void Function()? onDecode;

  final List<({Float32List samples, double offset, bool isFinal, int index})> calls =
      <({Float32List samples, double offset, bool isFinal, int index})>[];

  @override
  Segment decodeSamples(
    Float32List samples, {
    double offset = 0.0,
    bool isFinal = true,
    int index = -1,
  }) {
    final String text = calls.length < texts.length ? texts[calls.length] : '第${calls.length}段';
    calls.add((samples: samples, offset: offset, isFinal: isFinal, index: index));
    onDecode?.call();
    return Segment(
      text: text,
      start: offset,
      end: offset + samples.length / kSampleRate,
      isFinal: isFinal,
      index: index,
    );
  }
}
