import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';

import 'support/fake_asr.dart';

void main() {
  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('vsasr_batch_test');
    writeFakeModel(workspace.path);
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  TranscribeController buildController(AudioDecoder decoder) {
    return TranscribeController(
      decoder: decoder,
      models: ModelManager(root: workspace.path),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => FakeTranscriber(language: config.language),
    );
  }

  test('批量队列按顺序处理文件并去重', () async {
    final _RecordingDecoder decoder = _RecordingDecoder();
    final TranscribeController transcriber = buildController(decoder);
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: transcriber,
    );
    addTearDown(() async {
      batch.dispose();
      await transcriber.shutdown();
    });

    batch.enqueue(<String>['/tmp/a.wav', '  /tmp/b.wav  ', '/tmp/a.wav', '']);
    await batch.start();

    expect(decoder.paths, <String>['/tmp/a.wav', '/tmp/b.wav']);
    expect(batch.items, hasLength(2));
    expect(batch.items.map((BatchItem item) => item.status), <BatchItemStatus>[
      BatchItemStatus.completed,
      BatchItemStatus.completed,
    ]);
    expect(batch.completedCount, 2);
    expect(batch.running, isFalse);
  });

  test('恢复队列会去重，并把处理中和翻译中条目降级为可继续状态', () async {
    final TranscribeController transcriber = buildController(
      _RecordingDecoder(),
    );
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: transcriber,
    );
    addTearDown(() async {
      batch.dispose();
      await transcriber.shutdown();
    });

    batch.restore(<BatchItem>[
      const BatchItem(
        path: '  /tmp/processing.wav  ',
        status: BatchItemStatus.processing,
        progress: 0.4,
      ),
      const BatchItem(
        path: '/tmp/translating.wav',
        status: BatchItemStatus.translating,
        result: TranscriptionResult(
          duration: 1,
          segments: <Segment>[Segment(text: '原文', start: 0, end: 1)],
        ),
      ),
      const BatchItem(path: '/tmp/processing.wav'),
    ]);

    expect(batch.items, hasLength(2));
    expect(batch.items[0].path, '/tmp/processing.wav');
    expect(batch.items[0].status, BatchItemStatus.queued);
    expect(batch.items[0].progress, isNull);
    expect(batch.items[1].status, BatchItemStatus.completed);
    expect(batch.hasQueuedItems, isTrue);

    batch.clear();
    expect(batch.items, isEmpty);
  });

  test('暂停在当前文件完成后生效，继续后处理剩余文件', () async {
    final _RecordingDecoder decoder = _RecordingDecoder();
    final TranscribeController transcriber = buildController(decoder);
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: transcriber,
    );
    bool requestedPause = false;
    batch.addListener(() {
      final BatchItem? current = batch.currentItem;
      if (!requestedPause &&
          current?.status == BatchItemStatus.processing &&
          (current?.progress ?? 0) > 0) {
        requestedPause = true;
        batch.pause();
      }
    });
    addTearDown(() async {
      batch.dispose();
      await transcriber.shutdown();
    });

    batch.enqueue(<String>['/tmp/a.wav', '/tmp/b.wav']);
    await batch.start();

    expect(batch.paused, isTrue);
    expect(batch.items[0].status, BatchItemStatus.completed);
    expect(batch.items[1].status, BatchItemStatus.paused);

    await batch.resume();
    expect(batch.items[1].status, BatchItemStatus.completed);
  });

  test('最后一个文件完成后请求暂停不会留下虚假的暂停状态', () async {
    final _RecordingDecoder decoder = _RecordingDecoder();
    final TranscribeController transcriber = buildController(decoder);
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: transcriber,
    );
    bool requestedPause = false;
    batch.addListener(() {
      if (!requestedPause &&
          batch.currentItem?.status == BatchItemStatus.processing &&
          (batch.currentItem?.progress ?? 0) > 0) {
        requestedPause = true;
        batch.pause();
      }
    });
    addTearDown(() async {
      batch.dispose();
      await transcriber.shutdown();
    });

    batch.enqueue(<String>['/tmp/only.wav']);
    await batch.start();

    expect(batch.items.single.status, BatchItemStatus.completed);
    expect(batch.paused, isFalse);
  });

  test('失败文件不阻塞队列，重试只重新处理失败项', () async {
    final _FailOnceDecoder decoder = _FailOnceDecoder('/tmp/b.wav');
    final TranscribeController transcriber = buildController(decoder);
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: transcriber,
    );
    addTearDown(() async {
      batch.dispose();
      await transcriber.shutdown();
    });

    batch.enqueue(<String>['/tmp/a.wav', '/tmp/b.wav', '/tmp/c.wav']);
    await batch.start();

    expect(batch.items[0].status, BatchItemStatus.completed);
    expect(batch.items[1].status, BatchItemStatus.failed);
    expect(batch.items[2].status, BatchItemStatus.completed);

    await batch.retry(1);
    expect(batch.items[1].status, BatchItemStatus.completed);
    expect(decoder.paths, <String>[
      '/tmp/a.wav',
      '/tmp/b.wav',
      '/tmp/c.wav',
      '/tmp/b.wav',
    ]);
    expect(batch.items[1].attempts, 2);
  });

  test('批量翻译复用同一个 provider，单个文件失败不阻塞后续文件', () async {
    final _RecordingDecoder decoder = _RecordingDecoder();
    final TranscribeController transcriber = buildController(decoder);
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: transcriber,
    );
    final _BatchTranslationProvider provider = _BatchTranslationProvider(
      failOnCall: 1,
    );
    addTearDown(() async {
      batch.dispose();
      await transcriber.shutdown();
    });

    batch.enqueue(<String>['/tmp/a.wav', '/tmp/b.wav']);
    await batch.start();
    await batch.translateAll(provider, targetLanguage: 'zh-CN', maxRetries: 0);

    expect(provider.calls, 2);
    expect(batch.items[0].status, BatchItemStatus.translationFailed);
    expect(batch.items[1].status, BatchItemStatus.translated);
    expect(batch.items[1].result?.segments.single.translation, '译文：呢几个字都表达唔到');

    provider.failOnCall = null;
    batch.retryTranslation(0);
    await batch.translateAll(provider, targetLanguage: 'zh-CN', maxRetries: 0);
    expect(
      batch.items.every(
        (BatchItem item) => item.status == BatchItemStatus.translated,
      ),
      isTrue,
    );
    expect(provider.calls, 3);
  });

  test('取消批量翻译后，迟到结果不会写回译文', () async {
    final _RecordingDecoder decoder = _RecordingDecoder();
    final TranscribeController transcriber = buildController(decoder);
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: transcriber,
    );
    final Completer<List<String>> response = Completer<List<String>>();
    final _BatchTranslationProvider provider = _BatchTranslationProvider(
      response: response,
    );
    bool cancelRequested = false;
    batch.addListener(() {
      if (!cancelRequested &&
          batch.currentItem?.status == BatchItemStatus.translating) {
        cancelRequested = true;
        unawaited(batch.cancel());
      }
    });
    addTearDown(() async {
      batch.dispose();
      await transcriber.shutdown();
    });

    batch.enqueue(<String>['/tmp/a.wav']);
    await batch.start();
    final Future<void> translating = batch.translateAll(
      provider,
      targetLanguage: 'zh-CN',
      maxRetries: 0,
    );
    response.complete(<String>['迟到译文']);
    await translating;

    expect(cancelRequested, isTrue);
    expect(batch.items.single.status, BatchItemStatus.completed);
    expect(batch.items.single.result?.segments.single.translation, isNull);
  });

  test('取消会标记当前和后续条目，迟到结果不会写入条目', () async {
    final _RecordingDecoder decoder = _RecordingDecoder();
    final TranscribeController transcriber = buildController(decoder);
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: transcriber,
    );
    bool requestedCancel = false;
    batch.addListener(() {
      if (!requestedCancel &&
          batch.currentItem?.status == BatchItemStatus.processing &&
          (batch.currentItem?.progress ?? 0) > 0) {
        requestedCancel = true;
        unawaited(batch.cancel());
      }
    });
    addTearDown(() async {
      batch.dispose();
      await transcriber.shutdown();
    });

    batch.enqueue(<String>['/tmp/a.wav', '/tmp/b.wav']);
    await batch.start();

    expect(batch.items[0].status, BatchItemStatus.cancelled);
    expect(batch.items[0].result, isNull);
    expect(batch.items[1].status, BatchItemStatus.cancelled);
    expect(transcriber.result, isNull);
  });
}

class _RecordingDecoder implements AudioDecoder {
  final List<String> paths = <String>[];

  @override
  Future<Float32List> decodeFile(String path) async {
    paths.add(path);
    return Float32List(kSampleRate);
  }
}

class _FailOnceDecoder extends _RecordingDecoder {
  _FailOnceDecoder(this.failurePath);

  final String failurePath;
  bool failed = false;

  @override
  Future<Float32List> decodeFile(String path) async {
    paths.add(path);
    if (path == failurePath && !failed) {
      failed = true;
      throw AudioDecodeException('模拟解码失败', path: path);
    }
    return Float32List(kSampleRate);
  }
}

class _BatchTranslationProvider implements TranslationProvider {
  _BatchTranslationProvider({this.failOnCall, this.response});

  int? failOnCall;
  final Completer<List<String>>? response;
  int calls = 0;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) async {
    calls++;
    final Completer<List<String>>? pending = response;
    if (pending != null) return pending.future;
    if (failOnCall == calls) throw StateError('模拟翻译失败');
    return texts.map((String text) => '译文：$text').toList();
  }
}
