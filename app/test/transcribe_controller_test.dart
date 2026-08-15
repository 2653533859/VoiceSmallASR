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
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

import 'support/fake_asr.dart';

void main() {
  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('vsasr_ctrl_test'));
  tearDown(() => workspace.deleteSync(recursive: true));

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
      launch: ({
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
      launch: ({
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
    expect(stages, containsAllInOrder(<JobStage>[JobStage.decoding, JobStage.transcribing]));
    expect(c.stage, JobStage.idle);
    expect(c.filePath, '/tmp/a.wav');
    expect(c.result?.length, 1);
    expect(c.result?.segments.single.language, 'yue');
    expect(c.result?.duration, closeTo(2.0, 1e-9));
    expect(c.progress, 1);
    expect(c.statusText, '识别完成：1 段');
    expect(c.elapsed, isNotNull);
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
      launch: ({
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

    await c.setLanguage('yue');
    expect(c.language, 'yue');
    await c.transcribeFile('/tmp/a.wav');
    expect(launched, <String>['auto', 'yue']);
    expect(c.result?.segments.single.language, 'yue');
    await c.shutdown();
  });

  // 回归：切语言时旧 isolate 还在关，新的就抢先加载了 —— 两份 240 MB 模型
  // 同时躺在内存里，手机上直接爆。prepare() 必须先等旧的关完。
  test('切语言：旧转写器关完之前不会加载新模型', () async {
    final Completer<void> closing = Completer<void>();
    final List<String> events = <String>[];
    final TranscribeController c = TranscribeController(
      decoder: FakeDecoder(),
      models: models(),
      launch: ({
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

  // 回归：dispose() 只关「当下的」worker。模型加载要几十秒，界面在这期间
  // 被销毁时 _worker 还是 null，于是 isolate 与 240 MB 模型一起漏掉；
  // 而 prepare 的收尾还会 notifyListeners，抛 "used after being disposed"。
  test('模型还在加载时销毁控制器：迟到的转写器被收掉，且不抛 disposed 错误', () async {
    final Completer<void> gate = Completer<void>();
    final FakeTranscriber arrived = FakeTranscriber();
    final TranscribeController c = TranscribeController(
      models: models(),
      launch: ({
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
