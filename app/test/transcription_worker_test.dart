/// 后台识别 isolate 的测试。用替身工厂完全绕开原生库，
/// 因此不需要模型、不需要设备，`flutter test` 直接可跑。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';
import 'package:vsasr_app/src/asr/transcription_worker.dart';

void main() {
  test('结果能跨 isolate 完整传回（字段不丢）', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(
      config: AsrConfig(language: 'yue'),
      factory: fakeFactory,
    );
    addTearDown(worker.dispose);

    final TranscriptionResult result = await worker.transcribe(Float32List(16000));
    expect(result.segments, hasLength(1));
    expect(result.text, '呢几个字都表达唔到');
    expect(result.duration, closeTo(1.0, 1e-9));
    // 语言取自传进去的 AsrConfig：说明配置确实到了 isolate 里
    expect(result.language, 'yue');
    final Segment segment = result.segments.single;
    expect(segment.index, 0);
    expect(segment.isFinal, isTrue);
    expect(segment.words, hasLength(2));
    expect(segment.words.first.text, '呢');
    expect(segment.words.last.end, closeTo(0.6, 1e-9));
  });

  test('进度回调按顺序到达主 isolate', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(factory: fakeFactory);
    addTearDown(worker.dispose);

    final List<int> seen = <int>[];
    await worker.transcribe(
      Float32List(48000),
      onProgress: (int done, int total) {
        expect(total, 48000);
        seen.add(done);
      },
    );
    expect(seen, <int>[16000, 32000, 48000]);
  });

  test('多个请求串行处理，结果各归其主', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(factory: countingFactory);
    addTearDown(worker.dispose);

    final List<Future<TranscriptionResult>> requests = <Future<TranscriptionResult>>[
      worker.transcribe(Float32List(16000)),
      worker.transcribe(Float32List(32000)),
      worker.transcribe(Float32List(48000)),
    ];
    final List<TranscriptionResult> results = await Future.wait(requests);
    // countingFactory 的替身把「第几次调用」写进文本，串行才会是 1/2/3
    expect(results.map((TranscriptionResult r) => r.text), <String>['第1次', '第2次', '第3次']);
    // 时长各自对应自己的入参，没有串号
    expect(results.map((TranscriptionResult r) => r.duration), <double>[1.0, 2.0, 3.0]);
  });

  test('模型加载失败时 start() 抛错，且不留下野 isolate', () async {
    await expectLater(
      TranscriptionWorker.start(factory: failingFactory),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('模型缺失'),
        ),
      ),
    );
  });

  test('转写中途抛异常会变成 Future 的错误，worker 仍可继续用', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(factory: flakyFactory);
    addTearDown(worker.dispose);

    // flakyFactory 的替身：偶数次调用成功，奇数次抛
    await expectLater(
      worker.transcribe(Float32List(16000)),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('解码炸了'),
        ),
      ),
    );
    expect((await worker.transcribe(Float32List(16000))).text, '还活着');
  });

  test('dispose 之后再 transcribe 抛 StateError', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(factory: fakeFactory);
    await worker.dispose();
    expect(() => worker.transcribe(Float32List(16000)), throwsStateError);
    // 重复 dispose 是安全的
    await worker.dispose();
  });

  test('dispose 会让未完成的请求报错，而不是永远挂着', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(factory: slowFactory);
    final Future<TranscriptionResult> pending = worker.transcribe(Float32List(16000));
    final Future<void> failed = expectLater(pending, throwsStateError);
    // 替身永不返回，isolate 卡在 await for 里收不到关闭命令，只能等超时后硬杀
    await worker.dispose(gracePeriod: const Duration(milliseconds: 200));
    await failed;
  });

  test('模型下载进度经 onModelProgress 回报', () async {
    final List<String> stages = <String>[];
    final TranscriptionWorker worker = await TranscriptionWorker.start(
      factory: downloadingFactory,
      onModelProgress: (String stage, int done, int total) {
        stages.add('$stage $done/$total');
      },
    );
    addTearDown(worker.dispose);
    expect(stages, <String>['下载模型 50/100', '解压模型 100/100']);
  });

  test('实时会话：音频块送进去，局部段与定稿段按顺序回来', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(factory: liveFactory);
    addTearDown(worker.dispose);

    final LiveSession session = await worker.startLive();
    final List<String> seen = <String>[];
    final Completer<void> closed = Completer<void>();
    session.segments.listen(
      (Segment s) => seen.add('${s.text}|${s.isFinal}'),
      onDone: closed.complete,
    );

    session.accept(Float32List(1600));
    session.accept(Float32List(1600));
    await session.finish();
    await closed.future;

    // 定稿必须排在两条局部结果之后 —— finish 不能抢在段前面把流关掉
    expect(seen, <String>['局部1|false', '局部2|false', '定稿|true']);
  });

  test('同一时刻只能有一路实时会话；收尾后可以再开', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(factory: liveFactory);
    addTearDown(worker.dispose);

    final LiveSession first = await worker.startLive();
    await expectLater(worker.startLive(), throwsStateError);
    await first.finish();

    final LiveSession second = await worker.startLive();
    await second.finish();
  });

  test('关闭 worker 时会把还开着的实时会话收掉', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(factory: liveFactory);
    final LiveSession session = await worker.startLive();
    final Completer<void> closed = Completer<void>();
    session.segments.listen((Segment _) {}, onDone: closed.complete);

    await worker.dispose();
    await closed.future; // 没被收掉的话这里会一直挂着
  });

  // 回归：dispose() 先等实时会话收尾，而 isolate 可能卡在某次解码里 ——
  // 不给这一步设上限的话，连后面「超时硬杀」的兜底都走不到，退出直接挂死。
  test('实时会话收不了尾时 dispose 仍会在 gracePeriod 内返回', () async {
    final TranscriptionWorker worker = await TranscriptionWorker.start(factory: stuckLiveFactory);
    final LiveSession session = await worker.startLive();
    final Future<void> failed = expectLater(session.segments.toList(), throwsStateError);

    await worker.dispose(gracePeriod: const Duration(milliseconds: 200));
    await failed;
  });
}

// ── 以下工厂必须是顶层函数：闭包不能跨 isolate 传递 ──────────────────────

Future<Transcriber> fakeFactory(WorkerSetup setup) async =>
    _FakeTranscriber(setup.config.language);

Future<Transcriber> countingFactory(WorkerSetup setup) async => _CountingTranscriber();

Future<Transcriber> flakyFactory(WorkerSetup setup) async => _FlakyTranscriber();

Future<Transcriber> slowFactory(WorkerSetup setup) async => _SlowTranscriber();

Future<Transcriber> failingFactory(WorkerSetup setup) async {
  throw StateError('模型缺失，且 allowDownload=${setup.allowDownload}');
}

Future<Transcriber> downloadingFactory(WorkerSetup setup) async {
  setup.reportModelProgress('下载模型', 50, 100);
  setup.reportModelProgress('解压模型', 100, 100);
  return _FakeTranscriber(setup.config.language);
}

/// 只测整段转写的替身统一不支持实时会话。
mixin _NoLive implements Transcriber {
  @override
  Future<LiveSession> startLive() async => throw UnsupportedError('该替身不支持实时识别');
}

/// 实时会话替身：每收到一块音频出一条局部结果，收尾时补一条定稿。
Future<Transcriber> liveFactory(WorkerSetup setup) async => _LiveTranscriber();

/// 实时会话收不了尾的替身：`finish()` 永不返回。
Future<Transcriber> stuckLiveFactory(WorkerSetup setup) async => _StuckLiveTranscriber();

class _StuckLiveTranscriber with _NoLive implements Transcriber {
  @override
  Future<LiveSession> startLive() async => _StuckLive();

  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) async => const TranscriptionResult();

  @override
  Future<void> dispose() async {}
}

class _StuckLive implements LiveSession {
  final StreamController<Segment> _out = StreamController<Segment>.broadcast();

  @override
  Stream<Segment> get segments => _out.stream;

  @override
  void accept(Float32List chunk) {}

  @override
  Future<void> finish() => Completer<void>().future;
}

class _LiveTranscriber implements Transcriber {
  @override
  Future<LiveSession> startLive() async => _FakeLive();

  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) async => const TranscriptionResult();

  @override
  Future<void> dispose() async {}
}

class _FakeLive implements LiveSession {
  final StreamController<Segment> _out = StreamController<Segment>.broadcast();
  int _seen = 0;

  @override
  Stream<Segment> get segments => _out.stream;

  @override
  void accept(Float32List chunk) {
    _seen++;
    _out.add(Segment(text: '局部$_seen', start: 0.0, end: 1.0, isFinal: false));
  }

  @override
  Future<void> finish() async {
    _out.add(const Segment(text: '定稿', start: 0.0, end: 2.0, index: 0));
    await _out.close();
  }
}

/// 回一段固定结果，并按秒回报进度。
class _FakeTranscriber with _NoLive implements Transcriber {  _FakeTranscriber(this.language);

  final String language;

  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) async {
    for (int done = kSampleRate; done <= samples.length; done += kSampleRate) {
      onProgress?.call(done, samples.length);
    }
    return TranscriptionResult(
      segments: <Segment>[
        Segment(
          text: '呢几个字都表达唔到',
          start: 0.0,
          end: samples.length / kSampleRate,
          words: const <Word>[
            Word(text: '呢', start: 0.0, end: 0.3),
            Word(text: '几', start: 0.3, end: 0.6),
          ],
          language: language,
          index: 0,
        ),
      ],
      duration: samples.length / kSampleRate,
      language: language,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// 把「第几次调用」写进结果，用来验证请求是串行处理的。
class _CountingTranscriber with _NoLive implements Transcriber {
  int _calls = 0;

  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) async {
    final int seq = ++_calls;
    // 故意让先来的更慢：若实现是并发的，返回顺序就会乱
    await Future<void>.delayed(Duration(milliseconds: 30 - seq * 5));
    return TranscriptionResult(
      segments: <Segment>[
        Segment(text: '第$seq次', start: 0.0, end: 1.0, index: 0),
      ],
      duration: samples.length / kSampleRate,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// 第一次抛、之后成功。
class _FlakyTranscriber with _NoLive implements Transcriber {
  int _calls = 0;

  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) async {
    if (_calls++ == 0) throw StateError('解码炸了');
    return const TranscriptionResult(
      segments: <Segment>[Segment(text: '还活着', start: 0.0, end: 1.0, index: 0)],
      duration: 1.0,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// 永远不返回，用来测 dispose 时未完成请求的处理。
class _SlowTranscriber with _NoLive implements Transcriber {
  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) => Completer<TranscriptionResult>().future;

  @override
  Future<void> dispose() async {}
}
