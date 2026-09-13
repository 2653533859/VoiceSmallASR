import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/ui/folder_batch_controller.dart';
import 'package:vsasr_app/src/ui/folder_batch_store.dart';

class _Provider implements ClosableTranslationProvider {
  _Provider(this.events);
  final List<String> events;
  bool fail = false;
  bool closed = false;
  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) async {
    events.add('translate:${texts.single}');
    if (fail && texts.single == '1.mp4') {
      throw const TranslationException('bad key', statusCode: 401);
    }
    return texts.map((text) => '译文:$text').toList();
  }

  @override
  void close() => closed = true;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('folder_batch_test'));
  tearDown(() => dir.deleteSync(recursive: true));
  File file(String name) => File(p.join(dir.path, name));
  TranscriptionResult result(String path) => TranscriptionResult(
    segments: [Segment(text: p.basename(path), start: 0, end: 1)],
    language: 'ja',
  );

  test('扫描当前层、自然排序并识别同名和语言后缀字幕', () async {
    for (final name in [
      '10.mp4',
      '2.MP4',
      '1.ts',
      '3.wav',
      '4.mp4',
      'README',
      'other.txt',
    ]) {
      file(name).writeAsStringSync('');
    }
    Directory(p.join(dir.path, 'nested')).createSync();
    file('nested/0.mp4').writeAsStringSync('');
    file('1.SRT').writeAsStringSync('existing');
    file('2.ja.srt').writeAsStringSync('existing');
    file('3.zh-CN.vtt').writeAsStringSync('existing');
    file('4.other.ass').writeAsStringSync('unrelated');
    final c = FolderBatchController(
      transcribe: (path) async => result(path),
      prepareTranslation: () async => null,
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    expect(c.items.map((i) => p.basename(i.path)), [
      '1.ts',
      '2.MP4',
      '3.wav',
      '4.mp4',
      '10.mp4',
    ]);
    expect(c.items.map((i) => i.status), [
      FolderItemStatus.skipped,
      FolderItemStatus.skipped,
      FolderItemStatus.skipped,
      FolderItemStatus.queued,
      FolderItemStatus.queued,
    ]);
  });

  test('逐文件转写翻译落盘，复用并释放 provider，重跑不覆盖', () async {
    file('1.mp4').createSync();
    file('2.mp4').createSync();
    final events = <String>[];
    final provider = _Provider(events);
    int prepares = 0;
    final c = FolderBatchController(
      transcribe: (path) async {
        if (p.basename(path) == '2.mp4') {
          expect(file('1.srt').readAsStringSync(), contains('译文:1.mp4'));
        }
        events.add('transcribe:${p.basename(path)}');
        return result(path);
      },
      prepareTranslation: () async {
        prepares++;
        return (provider: provider, targetLanguage: 'ZH');
      },
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    await c.start();
    await c.start();
    expect(events, [
      'transcribe:1.mp4',
      'translate:1.mp4',
      'transcribe:2.mp4',
      'translate:2.mp4',
    ]);
    expect(prepares, 1);
    expect(provider.closed, isTrue);
    expect(file('2.srt').readAsStringSync(), contains('译文:2.mp4'));
    expect(
      c.items.every((i) => i.status == FolderItemStatus.completed),
      isTrue,
    );
  });

  test('翻译失败不生成字幕且继续下一个，再次开始只重试失败项', () async {
    file('1.mp4').createSync();
    file('2.mp4').createSync();
    final events = <String>[];
    final provider = _Provider(events)..fail = true;
    final c = FolderBatchController(
      transcribe: (path) async => result(path),
      prepareTranslation: () async =>
          (provider: provider, targetLanguage: 'ZH'),
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    await c.start();
    expect(c.items.first.status, FolderItemStatus.failed);
    expect(file('1.srt').existsSync(), isFalse);
    expect(file('2.srt').existsSync(), isTrue);
    provider.fail = false;
    await c.start();
    expect(events.where((e) => e == 'translate:2.mp4').length, 1);
    expect(file('1.srt').existsSync(), isTrue);
  });

  test('完成当前文件后停止，再继续剩余队列；关闭翻译不初始化 provider', () async {
    file('1.mp4').createSync();
    file('2.mp4').createSync();
    late FolderBatchController c;
    c = FolderBatchController(
      transcribe: (path) async {
        if (p.basename(path) == '1.mp4') c.stopAfterCurrent();
        return result(path);
      },
      prepareTranslation: () async => throw StateError('must not translate'),
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    await c.start(translate: false);
    expect(file('1.srt').existsSync(), isTrue);
    expect(c.paused, isTrue);
    expect(c.items.last.status, FolderItemStatus.queued);
    await c.start(translate: false);
    expect(file('2.srt').existsSync(), isTrue);
  });

  test('立即暂停会取消当前转写并把条目放回等待队列', () async {
    file('1.mp4').createSync();
    final started = Completer<void>();
    final cancelled = Completer<void>();
    late FolderBatchController c;
    c = FolderBatchController(
      transcribe: (_) async {
        started.complete();
        await cancelled.future;
        return null;
      },
      cancelCurrent: () async => cancelled.complete(),
      prepareTranslation: () async => null,
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    final running = c.start(translate: false);
    await started.future;

    await c.cancelNow();
    await running;

    expect(c.running, isFalse);
    expect(c.paused, isTrue);
    expect(c.items.single.status, FolderItemStatus.queued);
    expect(c.items.single.detail, contains('已暂停'));
  });

  test('开始前与转写期间出现字幕均保留原文件', () async {
    file('1.mp4').createSync();
    file('2.mp4').createSync();
    final c = FolderBatchController(
      transcribe: (path) async {
        expect(p.basename(path), '2.mp4');
        file('2.srt').writeAsStringSync('external');
        return result(path);
      },
      prepareTranslation: () async => null,
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    file('1.srt').writeAsStringSync('existing');
    await c.start(translate: false);
    expect(c.items.every((i) => i.status == FolderItemStatus.skipped), isTrue);
    expect(file('1.srt').readAsStringSync(), 'existing');
    expect(file('2.srt').readAsStringSync(), 'external');
  });

  test('取消翻译初始化不转写，无识别结果不写文件', () async {
    file('1.mp4').createSync();
    int calls = 0;
    final c = FolderBatchController(
      transcribe: (_) async {
        calls++;
        return const TranscriptionResult();
      },
      prepareTranslation: () async => null,
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    await c.start();
    expect(calls, 0);
    expect(c.running, isFalse);
    await c.start(translate: false);
    expect(c.items.single.status, FolderItemStatus.failed);
    expect(file('1.srt').existsSync(), isFalse);
  });

  test('恢复未完成队列及输出选项，处理中条目降级为等待', () async {
    file('1.mp4').createSync();
    final output = Directory(p.join(dir.path, 'output'))..createSync();
    final store = FolderBatchStore(rootDirectory: dir);
    await store.save(
      FolderBatchSnapshot(
        directory: dir.path,
        items: [
          FolderBatchSavedItem(
            path: file('1.mp4').path,
            status: FolderItemStatus.transcribing.name,
            detail: '转写中',
          ),
        ],
        translate: false,
        format: 'vtt',
        conflictPolicy: FolderConflictPolicy.numbered.name,
        outputDirectory: output.path,
      ),
    );
    final c = FolderBatchController(
      store: store,
      transcribe: (path) async => result(path),
      prepareTranslation: () async => null,
    );
    addTearDown(c.dispose);
    expect(await c.restore(), isTrue);
    expect(c.items.single.status, FolderItemStatus.queued);
    expect(c.items.single.detail, contains('意外中断'));
    expect(c.paused, isTrue);
    expect(c.translate, isFalse);
    expect(c.format, 'vtt');
    expect(c.outputDirectory, output.path);
    expect(c.conflictPolicy, FolderConflictPolicy.numbered);
  });

  test('可输出到独立目录并按格式自动编号，完成后清除恢复快照', () async {
    file('1.mp4').createSync();
    final output = Directory(p.join(dir.path, 'output'))..createSync();
    File(p.join(output.path, '1.vtt')).writeAsStringSync('existing');
    final storeRoot = Directory(p.join(dir.path, 'store'))..createSync();
    final store = FolderBatchStore(rootDirectory: storeRoot);
    final c = FolderBatchController(
      store: store,
      transcribe: (path) async => result(path),
      prepareTranslation: () async => null,
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    c.updateOptions(
      translate: false,
      format: 'vtt',
      outputDirectory: output.path,
      conflictPolicy: FolderConflictPolicy.numbered,
    );
    await c.start();
    await c.flush();
    expect(File(p.join(output.path, '1.vtt')).readAsStringSync(), 'existing');
    expect(
      File(p.join(output.path, '1 (2).vtt')).readAsStringSync(),
      startsWith('WEBVTT'),
    );
    expect(await store.load(), isNull);
  });

  test('独立输出目录已有目标且选择跳过时不会重复转写', () async {
    file('1.mp4').createSync();
    final output = Directory(p.join(dir.path, 'output'))..createSync();
    File(p.join(output.path, '1.txt')).writeAsStringSync('existing');
    var calls = 0;
    final c = FolderBatchController(
      transcribe: (path) async {
        calls++;
        return result(path);
      },
      prepareTranslation: () async => null,
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    c.updateOptions(
      translate: false,
      format: 'txt',
      outputDirectory: output.path,
    );
    await c.start();
    expect(calls, 0);
    expect(c.items.single.status, FolderItemStatus.skipped);
    expect(c.items.single.detail, contains('1.txt'));
    expect(File(p.join(output.path, '1.txt')).readAsStringSync(), 'existing');
  });

  test('支持整批语言和单文件覆盖，并提示识别语言冲突', () async {
    file('1.mp4').createSync();
    file('2.mp4').createSync();
    final languages = <String>[];
    final c = FolderBatchController(
      initialLanguage: 'ja',
      transcribeWithLanguage: (path, language) async {
        languages.add(language);
        return TranscriptionResult(
          segments: <Segment>[
            Segment(
              text: p.basename(path),
              start: 0,
              end: 1,
              language: path.endsWith('1.mp4') ? 'zh' : language,
            ),
          ],
          language: language,
        );
      },
      prepareTranslation: () async => null,
    );
    addTearDown(c.dispose);
    await c.selectDirectory(dir.path);
    c.updateOptions(translate: false);
    c.setItemLanguage(1, 'en');
    await c.start();
    expect(languages, <String>['ja', 'en']);
    expect(c.items.first.detail, contains('语言提示'));
    expect(c.items.last.detail, isNot(contains('语言提示')));
  });
}
