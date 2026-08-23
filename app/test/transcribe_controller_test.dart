/// 主界面状态机的测试：模型准备 → 解码 → 识别 → 导出。
///
/// 注入进程内替身转写器，因此不起 isolate、不加载原生库、不下载模型。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

import 'support/fake_asr.dart';

void main() {
  late Directory workspace;

  setUp(
    () => workspace = Directory.systemTemp.createTempSync('vsasr_ctrl_test'),
  );
  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  ModelManager models() => ModelManager(root: workspace.path);

  test('模型缺失时 refreshModel 报未就绪，造出文件后转为就绪', () async {
    final TranscribeController c = TranscribeController(models: models());
    await c.refreshModel();
    expect(c.modelReady, isFalse);
    expect(c.statusText, contains('下载模型'));

    writeFakeModel(workspace.path);
    await c.refreshModel();
    expect(c.modelReady, isTrue);
    expect(c.statusText, '模型就绪');
    expect(c.stage, JobStage.idle);
  });

  test('prepare 会把下载进度写进 statusText 与 progress', () async {
    final List<String> seen = <String>[];
    final TranscribeController c = TranscribeController(
      models: models(),
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            onModelProgress('下载 model.tar.bz2（源 1/3）', 50, 100);
            onModelProgress('解压识别模型…', 0, 0);
            return FakeTranscriber();
          },
    );
    c.addListener(() => seen.add('${c.statusText}|${c.progress}'));

    await c.prepare();
    expect(seen, contains('下载 model.tar.bz2（源 1/3）|0.5'));
    // total 为 0 时进度未知，应该是 null 而不是 0
    expect(seen, contains('解压识别模型…|null'));
    expect(c.modelReady, isTrue);
    expect(c.errorText, isNull);
    await c.shutdown();
  });

  test('模型准备失败时给出去掉前缀的中文错误，且可重试', () async {
    int attempts = 0;
    final TranscribeController c = TranscribeController(
      models: models(),
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            if (attempts++ == 0) throw StateError('模型不完整且已禁止下载');
            return FakeTranscriber();
          },
    );

    await c.prepare();
    expect(c.errorText, '模型不完整且已禁止下载'); // 不应残留 "Bad state: "
    expect(c.modelReady, isFalse);

    await c.prepare();
    expect(c.errorText, isNull);
    expect(c.modelReady, isTrue);
    await c.shutdown();
  });

  test('转写走完解码与识别两个阶段，结果与耗时都落地', () async {
    final FakeDecoder decoder = FakeDecoder(samples: 2 * kSampleRate);
    writeFakeModel(workspace.path);
    final FakeTranscriber transcriber = FakeTranscriber(language: 'yue');
    final List<JobStage> stages = <JobStage>[];
    final TranscribeController c = TranscribeController(
      decoder: decoder,
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => transcriber,
    );
    c.addListener(() {
      if (stages.isEmpty || stages.last != c.stage) stages.add(c.stage);
    });

    await c.transcribeFile('/tmp/a.wav');

    expect(decoder.decoded, <String>['/tmp/a.wav']);
    expect(
      stages,
      containsAllInOrder(<JobStage>[JobStage.decoding, JobStage.transcribing]),
    );
    expect(c.stage, JobStage.idle);
    expect(c.filePath, '/tmp/a.wav');
    expect(c.result?.length, 1);
    expect(c.result?.segments.single.language, 'yue');
    expect(c.result?.duration, closeTo(2.0, 1e-9));
    expect(c.progress, 1);
    expect(c.statusText, '识别完成：1 段');
    expect(c.elapsed, isNotNull);
    expect(c.performanceReport?.fileName, 'a.wav');
    expect(c.performanceReport?.sampleCount, 2 * kSampleRate);
    expect(c.performanceReport?.segmentCount, 1);
    expect(c.performanceReport?.realTimeFactor, isNotNull);
    expect(c.performanceReport?.toJsonString(), contains('decode_elapsed_ms'));
    expect(c.errorText, isNull);
    await c.shutdown();
  });

  test('解码失败时原样展示解码器的中文说明，不留下半个结果', () async {
    final TranscribeController c = TranscribeController(
      decoder: FakeDecoder(
        failure: const AudioDecodeException('当前平台尚未实现 .flac 的解码，暂时只支持 wav'),
      ),
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => FakeTranscriber(),
    );

    await c.transcribeFile('/tmp/a.flac');
    expect(c.errorText, contains('.flac'));
    expect(c.statusText, '解码失败');
    expect(c.result, isNull);
    expect(c.stage, JobStage.idle);
    await c.shutdown();
  });

  test('切语言会重启转写器，新结果用新语言', () async {
    final List<String> launched = <String>[];
    final TranscribeController c = TranscribeController(
      decoder: FakeDecoder(),
      models: models(),
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            launched.add(config.language);
            return FakeTranscriber(language: config.language);
          },
    );

    await c.transcribeFile('/tmp/a.wav');
    expect(c.result?.segments.single.language, 'auto');
    expect(c.performanceReport, isNotNull);

    await c.setLanguage('yue');
    expect(c.language, 'yue');
    expect(c.performanceReport, isNull);
    await c.transcribeFile('/tmp/a.wav');
    expect(launched, <String>['auto', 'yue']);
    expect(c.result?.segments.single.language, 'yue');
    await c.shutdown();
  });

  test('修改线程数等非语言配置也会重启转写器并使用新配置', () async {
    final List<AsrConfig> launched = <AsrConfig>[];
    final List<FakeTranscriber> workers = <FakeTranscriber>[];
    final TranscribeController c = TranscribeController(
      decoder: FakeDecoder(),
      models: models(),
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            launched.add(config);
            final FakeTranscriber worker = FakeTranscriber(
              language: config.language,
            );
            workers.add(worker);
            return worker;
          },
    );

    await c.transcribeFile('/tmp/a.wav');
    await c.applyConfig(c.config.copyWith(numThreads: 8, partialInterval: 1.2));

    expect(c.config.numThreads, 8);
    expect(c.config.partialInterval, 1.2);
    expect(workers.single.disposed, isTrue);

    await c.transcribeFile('/tmp/a.wav');
    expect(launched.map((AsrConfig config) => config.numThreads), <int>[2, 8]);
    expect(launched.map((AsrConfig config) => config.partialInterval), <double>[
      0.6,
      1.2,
    ]);
    await c.shutdown();
  });

  test('离线模式阻止自动准备下载，但显式下载仍可用', () async {
    final List<bool> allowDownloads = <bool>[];
    final TranscribeController c = TranscribeController(
      models: models(),
      offlineMode: true,
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            allowDownloads.add(allowDownload);
            return FakeTranscriber();
          },
    );

    await c.prepare();
    await c.shutdown();
    await c.downloadModel();

    expect(allowDownloads, <bool>[false, true]);
    await c.shutdown();
  });

  test('删除模型前关闭 worker，并清空模型状态和占用空间', () async {
    writeFakeModel(workspace.path);
    final FakeTranscriber worker = FakeTranscriber();
    final TranscribeController c = TranscribeController(
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => worker,
    );

    await c.prepare(allowDownload: false);
    await pumpEventQueue();
    expect(c.modelReady, isTrue);
    expect(c.modelBytes, greaterThan(0));

    await c.deleteModel();

    expect(worker.disposed, isTrue);
    expect(c.modelReady, isFalse);
    expect(c.modelBytes, 0);
    expect(await models().isReady(), isFalse);
    await c.shutdown();
  });

  test('删除模型会等待配置变更中的旧 worker 完成关闭', () async {
    writeFakeModel(workspace.path);
    final Completer<void> disposeGate = Completer<void>();
    final _BlockingTranscriber worker = _BlockingTranscriber(disposeGate);
    final TranscribeController c = TranscribeController(
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => worker,
    );

    await c.prepare(allowDownload: false);
    final Future<void> applying = c.applyConfig(
      c.config.copyWith(numThreads: 8),
    );
    await Future<void>.delayed(Duration.zero);
    final Future<void> deleting = c.deleteModel();
    await Future<void>.delayed(Duration.zero);

    expect(await models().isReady(), isTrue);
    disposeGate.complete();
    await Future.wait(<Future<void>>[applying, deleting]);
    expect(await models().isReady(), isFalse);
  });

  // 回归：切语言时旧 isolate 还在关，新的就抢先加载了 —— 两份 240 MB 模型
  // 同时躺在内存里，手机上直接爆。prepare() 必须先等旧的关完。
  test('切语言：旧转写器关完之前不会加载新模型', () async {
    final Completer<void> closing = Completer<void>();
    final List<String> events = <String>[];
    final TranscribeController c = TranscribeController(
      decoder: FakeDecoder(),
      models: models(),
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            events.add('起 ${config.language}');
            return _SlowClosingTranscriber(closing, events);
          },
    );

    await c.prepare();
    final Future<void> switching = c.setLanguage('yue');
    // 旧的卡在 dispose 里；这时候来一次转写请求
    final Future<void> job = c.transcribeFile('/tmp/a.wav');
    await pumpEventQueue();
    expect(events, <String>['起 auto', '关 auto']); // 新的还没起

    closing.complete();
    await switching;
    await job;
    expect(events, <String>['起 auto', '关 auto', '起 yue']);
    await c.shutdown();
  });

  test('renderResult 按格式出内容；没有结果时抛错', () async {
    final TranscribeController c = TranscribeController(
      decoder: FakeDecoder(),
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => FakeTranscriber(text: '开饭时间早上9点至下午5点。'),
    );
    expect(() => c.renderResult('srt'), throwsStateError);

    await c.transcribeFile('/tmp/a.wav');
    final String srt = c.renderResult('srt');
    expect(srt, startsWith('1\n'));
    expect(srt, contains('00:00:00,000 --> 00:00:01,000'));
    expect(srt, contains('开饭时间早上9点至下午5点。'));
    expect(c.renderResult('txt').trim(), '开饭时间早上9点至下午5点。');
    expect(c.renderResult('json'), contains('"segments"'));
    expect(() => c.renderResult('ass'), throwsArgumentError);
    await c.shutdown();
  });

  test('翻译成功后一次性写回所有译文并报告状态', () async {
    final TranscribeController c = TranscribeController(
      decoder: FakeDecoder(),
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => FakeTranscriber(text: 'hello'),
    );

    await c.transcribeFile('/tmp/a.wav');
    final _FakeTranslationProvider provider = _FakeTranslationProvider();
    await c.translateCurrentResult(provider);

    expect(provider.calls, 1);
    expect(c.result?.segments.single.translation, '译文：hello');
    expect(c.statusText, '翻译完成：1 段');
    expect(c.progress, 1);
    expect(c.errorText, isNull);
    await c.shutdown();
  });

  test('翻译失败时保留原结果并回到空闲状态', () async {
    final TranscribeController c = TranscribeController(
      decoder: FakeDecoder(),
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => FakeTranscriber(text: 'hello'),
    );

    await c.transcribeFile('/tmp/a.wav');
    final TranscriptionResult? before = c.result;
    await c.translateCurrentResult(
      _FakeTranslationProvider(failure: StateError('服务不可用')),
    );

    expect(c.result, same(before));
    expect(c.stage, JobStage.idle);
    expect(c.statusText, '翻译失败');
    expect(c.errorText, contains('服务不可用'));
    await c.shutdown();
  });

  test('视频流式转写逐段回报字幕且不覆盖当前项目', () async {
    final _StreamingFakeDecoder decoder = _StreamingFakeDecoder();
    final FakeTranscriber worker = FakeTranscriber(
      language: 'en',
      liveSegments: const <Segment>[
        Segment(
          text: 'first subtitle',
          start: 0,
          end: 1,
          language: 'en',
          index: 0,
        ),
      ],
    );
    final TranscribeController c = TranscribeController(
      decoder: decoder,
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => worker,
    );
    c.applyImportedResult(
      const TranscriptionResult(
        segments: <Segment>[
          Segment(text: 'existing', start: 0, end: 1, index: 0),
        ],
        duration: 1,
      ),
      mediaPath: '/tmp/existing.mp4',
    );
    final List<TranscriptionResult> updates = <TranscriptionResult>[];

    final TranscriptionResult result = await c.transcribeVideoStream(
      '/tmp/next.mp4',
      onUpdate: updates.add,
    );

    expect(result.segments.single.text, 'first subtitle');
    expect(updates, isNotEmpty);
    expect(c.filePath, '/tmp/existing.mp4');
    expect(c.result?.segments.single.text, 'existing');
    expect(c.stage, JobStage.idle);
    expect(decoder.decodeFileCalls, 0);
    expect(decoder.decodeChunkCalls, 1);
    expect(worker.live?.chunks, hasLength(2));
    await c.shutdown();
  });

  test('视频流式转写等待上一块消费完毕，避免长视频音频无限积压', () async {
    final _BackpressureDecoder decoder = _BackpressureDecoder();
    final Completer<void> firstChunkConsumed = Completer<void>();
    final FakeLiveSession live = FakeLiveSession(
      onAccept: (_, _) async {
        if (!firstChunkConsumed.isCompleted) await firstChunkConsumed.future;
      },
    );
    final TranscribeController c = TranscribeController(
      decoder: decoder,
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => _ProvidedLiveTranscriber(live),
    );

    final Future<TranscriptionResult> running = c.transcribeVideoStream(
      '/tmp/long.mp4',
    );
    await pumpEventQueue();

    expect(decoder.yieldedChunks, 1);
    expect(live.chunks, hasLength(1));
    expect(c.statusText, contains('已解码 10 秒，已识别 0 秒'));

    firstChunkConsumed.complete();
    final TranscriptionResult result = await running;

    expect(decoder.yieldedChunks, 3);
    expect(live.chunks, hasLength(3));
    expect(result.duration, 30);
    await c.shutdown();
  });

  test('播放列表切换后视频流式转写在当前块完成时立即取消并释放会话', () async {
    final _BackpressureDecoder decoder = _BackpressureDecoder();
    var cancelled = false;
    final FakeLiveSession live = FakeLiveSession(
      onAccept: (_, _) async => cancelled = true,
    );
    final TranscribeController c = TranscribeController(
      decoder: decoder,
      models: models(),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => _ProvidedLiveTranscriber(live),
    );

    await expectLater(
      c.transcribeVideoStream('/tmp/long.mp4', isCancelled: () => cancelled),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          '视频字幕转写已取消',
        ),
      ),
    );

    expect(decoder.yieldedChunks, 1);
    expect(live.chunks, hasLength(1));
    expect(live.finished, isTrue);
    await c.shutdown();
  });

  // 回归：dispose() 只关「当下的」worker。模型加载要几十秒，界面在这期间
  // 被销毁时 _worker 还是 null，于是 isolate 与 240 MB 模型一起漏掉；
  // 而 prepare 的收尾还会 notifyListeners，抛 "used after being disposed"。
  test('模型还在加载时销毁控制器：迟到的转写器被收掉，且不抛 disposed 错误', () async {
    final Completer<void> gate = Completer<void>();
    final FakeTranscriber arrived = FakeTranscriber();
    final TranscribeController c = TranscribeController(
      models: models(),
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            await gate.future;
            return arrived;
          },
    );

    final Future<void> preparing = c.prepare();
    c.dispose(); // 界面先没了
    gate.complete(); // 模型这才加载完
    await preparing; // 不应抛 FlutterError

    expect(arrived.disposed, isTrue);
  });
}

class _StreamingFakeDecoder implements AudioDecoder, ChunkedAudioDecoder {
  int decodeFileCalls = 0;
  int decodeChunkCalls = 0;

  @override
  Future<Float32List> decodeFile(String path) async {
    decodeFileCalls++;
    return Float32List(2 * kSampleRate);
  }

  @override
  Stream<DecodedAudioChunk> decodeFileChunks(
    String path, {
    Duration chunkDuration = const Duration(seconds: 10),
  }) async* {
    decodeChunkCalls++;
    yield DecodedAudioChunk(Float32List(kSampleRate), isLast: false);
    yield DecodedAudioChunk(Float32List(kSampleRate), isLast: true);
  }
}

class _BackpressureDecoder implements AudioDecoder, ChunkedAudioDecoder {
  int yieldedChunks = 0;

  @override
  Future<Float32List> decodeFile(String path) async => Float32List(0);

  @override
  Stream<DecodedAudioChunk> decodeFileChunks(
    String path, {
    Duration chunkDuration = const Duration(seconds: 10),
  }) async* {
    for (int index = 0; index < 3; index++) {
      yieldedChunks++;
      yield DecodedAudioChunk(
        Float32List(10 * kSampleRate),
        isLast: index == 2,
      );
    }
  }
}

class _ProvidedLiveTranscriber implements Transcriber {
  _ProvidedLiveTranscriber(this.session);

  final LiveSession session;

  @override
  Future<LiveSession> startLive() async => session;

  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) async => const TranscriptionResult();

  @override
  Future<void> dispose() async {}
}

class _FakeTranslationProvider implements TranslationProvider {
  _FakeTranslationProvider({this.failure});

  final Object? failure;
  int calls = 0;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) async {
    calls++;
    final Object? error = failure;
    if (error != null) throw error;
    return texts.map((String text) => '译文：$text').toList();
  }
}

class _BlockingTranscriber extends FakeTranscriber {
  _BlockingTranscriber(this._disposeGate);

  final Completer<void> _disposeGate;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _disposeGate.future;
  }
}

/// 关得很慢的转写器：用来卡住切语言时的收尾。
class _SlowClosingTranscriber implements Transcriber {
  _SlowClosingTranscriber(this._gate, this._events);

  final Completer<void> _gate;
  final List<String> _events;
  final FakeTranscriber _inner = FakeTranscriber();

  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) => _inner.transcribe(samples, onProgress: onProgress);

  @override
  Future<LiveSession> startLive() => _inner.startLive();

  @override
  Future<void> dispose() async {
    _events.add('关 auto');
    await _gate.future;
  }
}
