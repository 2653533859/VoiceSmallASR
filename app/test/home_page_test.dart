/// 主界面的 widget 测试：模型下载页 → 选文件 → 分段列表 → 导出。
///
/// 全部依赖都用替身，不起 isolate、不加载原生库、不弹真实文件对话框。
library;

import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/project/project_file.dart';
import 'package:vsasr_app/src/project/batch_translation_cache.dart';
import 'package:vsasr_app/src/ui/batch_queue_store.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/settings/translation_secrets.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';
import 'package:vsasr_app/src/ui/home_page.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';

import 'support/fake_asr.dart';

void main() {
  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('vsasr_ui_test'));
  tearDown(() => workspace.deleteSync(recursive: true));

  /// 造一个控制器：默认模型已就绪、转写器是进程内替身。
  TranscribeController build({
    bool modelReady = true,
    AudioDecoder? decoder,
    AudioDecodeException? decodeFailure,
    String text = '呢几个字都表达唔到',
  }) {
    if (modelReady) writeFakeModel(workspace.path);
    return TranscribeController(
      decoder: decoder ?? FakeDecoder(failure: decodeFailure),
      models: ModelManager(root: workspace.path),
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            onModelProgress('下载 model.tar.bz2（源 1/3）', 40, 100);
            return FakeTranscriber(language: config.language, text: text);
          },
    );
  }

  Future<void> show(
    WidgetTester tester,
    TranscribeController controller, {
    PickFile? pickFile,
    PickBatchFiles? pickBatchFiles,
    PickProjectFile? pickProjectFile,
    PickSubtitleFile? pickSubtitleFile,
    LoadProjectFile? loadProjectFile,
    SaveFile? saveFile,
    ProjectAutosaveStore? autosaveStore,
    MediaFileExists? mediaFileExists,
    BatchTranslationCache? batchTranslationCache,
    BatchQueueStore? batchQueueStore,
    AppSettingsRepository? settings,
    TranslationProviderFactory? translationProviderFactory,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          key: ObjectKey(controller),
          controller: controller,
          pickFile: pickFile,
          pickBatchFiles: pickBatchFiles,
          pickProjectFile: pickProjectFile,
          pickSubtitleFile: pickSubtitleFile,
          loadProjectFile: loadProjectFile,
          saveFile: saveFile,
          autosaveStore: autosaveStore ?? _FakeAutosaveStore(),
          batchTranslationCache:
              batchTranslationCache ?? const _NoopBatchTranslationCache(),
          batchQueueStore: batchQueueStore ?? _FakeBatchQueueStore(),
          mediaFileExists:
              mediaFileExists ?? (String path) async => File(path).existsSync(),
          settings: settings,
          translationProviderFactory: translationProviderFactory,
        ),
      ),
    );
    // postFrameCallback 里的 refreshModel 是异步的，再走一帧才能看到结果
    await tester.pump();
    await tester.pump();
  }

  testWidgets('模型缺失时先显示下载页，下载完成后进入主界面', (WidgetTester tester) async {
    final TranscribeController controller = build(modelReady: false);
    addTearDown(controller.shutdown);
    await show(tester, controller);

    expect(find.text('首次使用需要下载模型'), findsOneWidget);
    expect(find.textContaining('依次尝试 GitHub 与两个镜像源'), findsOneWidget);
    expect(find.text('选择音频/视频'), findsNothing);

    await tester.tap(find.text('下载模型'));
    await tester.pump(); // 进入 preparingModel
    await tester.pump(); // 替身返回，模型就绪

    expect(find.text('选择音频/视频'), findsOneWidget);
    expect(find.text('选一个音频或视频文件开始'), findsOneWidget);
  });

  testWidgets('首页可以导入 SRT 字幕并生成当前结果', (WidgetTester tester) async {
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      pickSubtitleFile: () async => SubtitleFileData(
        name: 'captions.srt',
        bytes: Uint8List.fromList(
          utf8.encode('1\n00:00:00,000 --> 00:00:01,500\n外部字幕\n'),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('importSubtitle')));
    await tester.pumpAndSettle();

    expect(controller.result?.segments.single.text, '外部字幕');
    expect(find.text('外部字幕'), findsOneWidget);
    expect(find.textContaining('已导入字幕：captions.srt'), findsOneWidget);
  });

  testWidgets('首页可以打开批量处理页并顺序完成多个文件', (WidgetTester tester) async {
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      pickBatchFiles: () async => <String>['/tmp/one.wav', '/tmp/two.wav'],
    );

    await tester.tap(find.byKey(const Key('openBatchProcessing')));
    await tester.pumpAndSettle();
    expect(find.text('批量处理'), findsOneWidget);

    await tester.tap(find.byKey(const Key('batchPickFiles')));
    await tester.pumpAndSettle();
    expect(find.text('one.wav'), findsOneWidget);
    expect(find.text('two.wav'), findsOneWidget);

    await tester.tap(find.byKey(const Key('batchStart')));
    await tester.pumpAndSettle();
    expect(find.text('已完成 2/2'), findsOneWidget);
    expect(controller.result, isNotNull);
  });

  testWidgets('批量翻译复用配置的 provider 并显示翻译完成状态', (WidgetTester tester) async {
    final _FakeSecretStore secrets = _FakeSecretStore()
      ..values[kTranslationApiKeyStorageKey] = 'test-key';
    final AppSettingsRepository settings = AppSettingsRepository(
      preferences: _FakePreferenceStore(),
      secrets: TranslationSecrets(store: secrets),
    );
    final _FakeTranslationProvider provider = _FakeTranslationProvider();
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      settings: settings,
      translationProviderFactory: (_) => provider,
      pickBatchFiles: () async => <String>['/tmp/one.wav', '/tmp/two.wav'],
    );

    await tester.tap(find.byKey(const Key('openBatchProcessing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchPickFiles')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchStart')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchTranslate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续翻译'));
    await tester.pumpAndSettle();

    expect(provider.calls, 2);
    expect(find.text('已翻译 2/2'), findsOneWidget);
    expect(find.textContaining('已完成翻译'), findsNWidgets(2));
  });

  testWidgets('批量翻译命中本地缓存时不调用 provider', (WidgetTester tester) async {
    final TranscriptionResult cachedResult = const TranscriptionResult(
      language: 'auto',
      duration: 1,
      segments: <Segment>[
        Segment(
          text: '呢几个字都表达唔到',
          start: 0,
          end: 1,
          words: <Word>[Word(text: '呢几个字都表达唔到', start: 0, end: 1)],
          language: 'auto',
          index: 0,
          translation: '缓存译文',
        ),
      ],
    );
    final _MemoryBatchTranslationCache cache = _MemoryBatchTranslationCache(
      cachedResult,
    );
    final AppSettingsRepository settings = AppSettingsRepository(
      preferences: _FakePreferenceStore(),
      secrets: TranslationSecrets(store: _FakeSecretStore()),
    );
    final _FakeTranslationProvider provider = _FakeTranslationProvider();
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      batchTranslationCache: cache,
      settings: settings,
      translationProviderFactory: (_) => provider,
      pickBatchFiles: () async => <String>['/tmp/cache.wav'],
    );
    await tester.tap(find.byKey(const Key('openBatchProcessing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchPickFiles')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchStart')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchTranslate')));
    await tester.pumpAndSettle();

    expect(find.text('发现本地翻译缓存'), findsOneWidget);
    await tester.tap(find.text('复用缓存'));
    await tester.pumpAndSettle();

    expect(provider.calls, 0);
    expect(find.text('已翻译 1/1'), findsOneWidget);
    expect(find.textContaining('已复用 1 个本地翻译缓存'), findsOneWidget);
  });

  testWidgets('批量导出支持四种格式并为同名文件生成不冲突的文件名', (WidgetTester tester) async {
    final List<(String, String)> saved = <(String, String)>[];
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      pickBatchFiles: () async => <String>[
        '/tmp/left/episode.wav',
        '/tmp/right/episode.mp3',
      ],
      saveFile: (String name, String content) async {
        saved.add((name, content));
        return '/tmp/$name';
      },
    );

    await tester.tap(find.byKey(const Key('openBatchProcessing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchPickFiles')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchStart')));
    await tester.pumpAndSettle();

    for (final String format in kSubtitleFormats) {
      await tester.tap(find.byKey(const Key('batchExport')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('${format.toUpperCase()} —'));
      await tester.pumpAndSettle();
    }

    expect(saved.map((entry) => entry.$1), <String>[
      'episode.srt',
      'episode-2.srt',
      'episode.vtt',
      'episode-2.vtt',
      'episode.json',
      'episode-2.json',
      'episode.txt',
      'episode-2.txt',
    ]);
    expect(saved[0].$2, contains('00:00:00,000 --> 00:00:01,000'));
    expect(saved[2].$2, startsWith('WEBVTT'));
    expect(saved[4].$2, contains('"segments"'));
    expect(saved[6].$2, contains('呢几个字都表达唔到'));
  });

  testWidgets('批量导出取消一个保存后停止后续文件', (WidgetTester tester) async {
    int saveCalls = 0;
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      pickBatchFiles: () async => <String>['/tmp/one.wav', '/tmp/two.wav'],
      saveFile: (String name, String content) async {
        saveCalls++;
        return null;
      },
    );

    await tester.tap(find.byKey(const Key('openBatchProcessing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchPickFiles')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchStart')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchExport')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('SRT —'));
    await tester.pumpAndSettle();

    expect(saveCalls, 1);
    expect(find.textContaining('已导出 0/2 个文件，已取消剩余导出'), findsOneWidget);
  });

  testWidgets('模型准备失败时显示错误并把按钮改成重试', (WidgetTester tester) async {
    final TranscribeController controller = TranscribeController(
      models: ModelManager(root: workspace.path),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => throw StateError('三个源都没下成：连接超时'),
    );
    addTearDown(controller.shutdown);
    await show(tester, controller);

    await tester.tap(find.text('下载模型'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('三个源都没下成'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('选中文件后列出分段、时间戳与语言，并显示统计', (WidgetTester tester) async {
    final TranscribeController controller = build(
      decoder: FakeDecoder(samples: 2 * kSampleRate),
    );
    addTearDown(controller.shutdown);
    await show(tester, controller, pickFile: () async => '/tmp/yue.wav');

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(find.text('呢几个字都表达唔到'), findsOneWidget);
    expect(find.textContaining('00:00:00.000 → 00:00:02.000'), findsOneWidget);
    expect(find.text('yue.wav'), findsOneWidget);
    // 底部统计与状态行都会提到段数，这里只认底部那条完整统计
    expect(find.textContaining('1 段　音频 2.00s'), findsOneWidget);
    expect(find.text('识别完成：1 段'), findsOneWidget);
  });

  testWidgets('打开项目文件后恢复字幕、媒体路径和配置', (WidgetTester tester) async {
    const String projectPath = '/tmp/demo.vsasr.json';
    final String restoredMediaPath = '${workspace.path}/restored.wav';
    File(restoredMediaPath).writeAsStringSync('media');
    final VsasrProject project = VsasrProject(
      mediaPath: restoredMediaPath,
      config: AsrConfig(language: 'en'),
      result: TranscriptionResult(
        language: 'en',
        duration: 1.5,
        segments: <Segment>[
          Segment(text: '恢复的字幕', start: 0, end: 1.5, language: 'en'),
        ],
      ),
    );
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      pickProjectFile: () async =>
          const PickedProjectFile(name: 'demo.vsasr.json', path: projectPath),
      loadProjectFile: (String path) async {
        expect(path, projectPath);
        return project;
      },
    );

    await tester.tap(find.text('打开项目'));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('恢复的字幕'), findsOneWidget);
    expect(controller.filePath, restoredMediaPath);
    expect(controller.language, 'en');
    expect(find.text('已打开项目：demo.vsasr.json'), findsOneWidget);
  });

  testWidgets('项目媒体缺失时可以重新定位并更新项目引用', (WidgetTester tester) async {
    final String missingMediaPath = '${workspace.path}/missing.wav';
    final String relocatedMediaPath = '${workspace.path}/relocated.wav';
    File(relocatedMediaPath).writeAsStringSync('media');
    final VsasrProject project = VsasrProject(
      mediaPath: missingMediaPath,
      config: AsrConfig(language: 'en'),
      result: const TranscriptionResult(
        language: 'en',
        duration: 1,
        segments: <Segment>[
          Segment(text: '媒体缺失字幕', start: 0, end: 1, language: 'en'),
        ],
      ),
    );
    final _FakeAutosaveStore autosave = _FakeAutosaveStore();
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      autosaveStore: autosave,
      pickFile: () async => relocatedMediaPath,
      pickProjectFile: () async => const PickedProjectFile(
        name: 'missing.vsasr.json',
        path: '/tmp/missing.vsasr.json',
      ),
      loadProjectFile: (String path) async => project,
    );

    await tester.tap(find.text('打开项目'));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('媒体文件不存在'), findsOneWidget);

    await tester.tap(find.text('重新选择媒体'));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(controller.filePath, relocatedMediaPath);
    expect(find.text('媒体文件已重新定位：relocated.wav'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(autosave.project?.mediaPath, relocatedMediaPath);
  });

  testWidgets('识别完成后会自动保存可恢复快照', (WidgetTester tester) async {
    final _FakeAutosaveStore autosave = _FakeAutosaveStore();
    final TranscribeController controller = build(text: '自动保存的字幕');
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      autosaveStore: autosave,
      pickFile: () async => '/tmp/autosave.wav',
    );

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();

    expect(autosave.saves, 1);
    expect(autosave.project?.mediaPath, '/tmp/autosave.wav');
    expect(autosave.project?.result.segments.single.text, '自动保存的字幕');
  });

  testWidgets('启动时可以恢复上次自动保存的项目', (WidgetTester tester) async {
    final String recoveryMediaPath = '${workspace.path}/recovery.wav';
    File(recoveryMediaPath).writeAsStringSync('media');
    final VsasrProject project = VsasrProject(
      mediaPath: recoveryMediaPath,
      config: AsrConfig(language: 'en'),
      result: const TranscriptionResult(
        language: 'en',
        duration: 1,
        segments: <Segment>[
          Segment(text: '恢复快照字幕', start: 0, end: 1, language: 'en'),
        ],
      ),
    );
    final _FakeAutosaveStore autosave = _FakeAutosaveStore(project);
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(tester, controller, autosaveStore: autosave);
    await tester.pumpAndSettle();

    expect(find.text('发现未完成的项目'), findsOneWidget);
    await tester.tap(find.text('恢复项目'));
    await tester.pumpAndSettle();

    expect(controller.filePath, recoveryMediaPath);
    expect(controller.language, 'en');
    expect(find.text('恢复快照字幕'), findsOneWidget);
  });

  testWidgets('异常退出后可以恢复批量任务队列', (WidgetTester tester) async {
    final _FakeAutosaveStore autosave = _FakeAutosaveStore()
      ..previousSessionUnclean = true;
    final _FakeBatchQueueStore queue = _FakeBatchQueueStore(
      const BatchQueueSnapshot(
        items: <BatchItem>[
          BatchItem(path: '/tmp/recover.wav'),
          BatchItem(
            path: '/tmp/failed.wav',
            status: BatchItemStatus.failed,
            errorText: '解码失败',
          ),
        ],
      ),
    );
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      autosaveStore: autosave,
      batchQueueStore: queue,
    );
    await tester.pumpAndSettle();

    expect(find.text('发现未完成的批量任务'), findsOneWidget);
    await tester.tap(find.text('恢复任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openBatchProcessing')));
    await tester.pumpAndSettle();

    expect(find.text('recover.wav'), findsOneWidget);
    expect(find.text('failed.wav'), findsOneWidget);
    expect(find.textContaining('已恢复 2 个批量任务'), findsOneWidget);
  });

  testWidgets('放弃批量任务恢复时会清理队列快照', (WidgetTester tester) async {
    final _FakeAutosaveStore autosave = _FakeAutosaveStore()
      ..previousSessionUnclean = true;
    final _FakeBatchQueueStore queue = _FakeBatchQueueStore(
      const BatchQueueSnapshot(
        items: <BatchItem>[BatchItem(path: '/tmp/discard.wav')],
      ),
    );
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      autosaveStore: autosave,
      batchQueueStore: queue,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('放弃任务'));
    await tester.pumpAndSettle();

    expect(queue.clears, 1);
    expect(queue.snapshot, isNull);
  });

  testWidgets('批量队列变化会自动保存快照', (WidgetTester tester) async {
    final _FakeBatchQueueStore queue = _FakeBatchQueueStore();
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      batchQueueStore: queue,
      pickBatchFiles: () async => <String>['/tmp/persisted.wav'],
    );

    await tester.tap(find.byKey(const Key('openBatchProcessing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batchPickFiles')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();

    expect(queue.saves, greaterThanOrEqualTo(1));
    expect(queue.snapshot?.items.single.path, '/tmp/persisted.wav');
  });

  testWidgets('没有本地路径时也可以从 SAF 字节打开项目', (WidgetTester tester) async {
    final String safMediaPath = '${workspace.path}/saf.wav';
    File(safMediaPath).writeAsStringSync('media');
    final VsasrProject project = VsasrProject(
      mediaPath: safMediaPath,
      config: AsrConfig(language: 'zh'),
      result: const TranscriptionResult(
        language: 'zh',
        duration: 1,
        segments: <Segment>[
          Segment(text: 'SAF 字节字幕', start: 0, end: 1, language: 'zh'),
        ],
      ),
    );
    final Uint8List bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(project.toJson())),
    );
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      pickProjectFile: () async =>
          PickedProjectFile(name: 'saf.vsasr.json', bytes: bytes),
    );

    await tester.tap(find.text('打开项目'));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(find.text('SAF 字节字幕'), findsOneWidget);
    expect(controller.filePath, safMediaPath);
  });

  testWidgets('保存项目会交给保存器并保留项目 JSON', (WidgetTester tester) async {
    final List<(String, String)> saved = <(String, String)>[];
    final TranscribeController controller = build(text: '可保存的字幕');
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      pickFile: () async => '/tmp/save.wav',
      saveFile: (String name, String content) async {
        saved.add((name, content));
        return '/tmp/$name';
      },
    );

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.tap(find.text('保存项目'));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(saved, hasLength(1));
    expect(saved.single.$1, 'VoiceSmallASR.vsasr.json');
    expect(saved.single.$2, contains('voicesmallasr.project'));
    expect(saved.single.$2, contains('可保存的字幕'));
    expect(find.text('项目已保存到 /tmp/VoiceSmallASR.vsasr.json'), findsOneWidget);
  });

  testWidgets('保存项目后会出现在最近项目菜单，并可再次打开', (WidgetTester tester) async {
    bool openedRecent = false;
    final AppSettingsRepository settings = AppSettingsRepository(
      preferences: _FakePreferenceStore(),
    );
    final TranscribeController controller = build(text: '最近项目字幕');
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      settings: settings,
      pickFile: () async => '/tmp/recent.wav',
      saveFile: (String name, String content) async => '/tmp/recent.vsasr.json',
      loadProjectFile: (String path) async {
        expect(path, '/tmp/recent.vsasr.json');
        openedRecent = true;
        return controller.projectSnapshot;
      },
    );

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.tap(find.text('保存项目'));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    await tester.tap(find.byKey(const Key('recentProjects')));
    await tester.pumpAndSettle();
    expect(find.text('recent.vsasr.json'), findsOneWidget);
    await tester.tap(find.text('recent.vsasr.json'));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(openedRecent, isTrue);
    expect(find.text('最近项目字幕'), findsOneWidget);
  });

  testWidgets('解码失败时把中文说明显示在错误框里', (WidgetTester tester) async {
    final TranscribeController controller = build(
      decodeFailure: const AudioDecodeException('系统无法解码该格式（mkv / webm 需先转码）'),
    );
    addTearDown(controller.shutdown);
    await show(tester, controller, pickFile: () async => '/tmp/a.mkv');

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(find.textContaining('mkv / webm 需先转码'), findsOneWidget);
    expect(find.text('解码失败'), findsOneWidget);
    expect(find.text('选一个音频或视频文件开始'), findsOneWidget);
  });

  testWidgets('导出：选格式 → 交给保存器 → 提示落地位置', (WidgetTester tester) async {
    final List<(String, String)> saved = <(String, String)>[];
    final TranscribeController controller = build(text: '开饭时间早上9点至下午5点。');
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      pickFile: () async => '/tmp/zh.wav',
      saveFile: (String name, String content) async {
        saved.add((name, content));
        return '/Users/me/Desktop/$name';
      },
    );

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }

    await tester.tap(find.text('导出字幕'));
    await tester.pumpAndSettle();
    expect(find.text('导出格式'), findsOneWidget);
    // 四种格式都在
    for (final String format in <String>['SRT', 'VTT', 'JSON', 'TXT']) {
      expect(find.textContaining('$format — '), findsOneWidget);
    }

    await tester.tap(find.textContaining('SRT — '));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.$1, 'zh.srt'); // 文件名跟着音频名走
    expect(saved.single.$2, contains('00:00:00,000 --> 00:00:01,000'));
    expect(saved.single.$2, contains('开饭时间早上9点至下午5点。'));
    expect(
      find.textContaining('已导出到 /Users/me/Desktop/zh.srt'),
      findsOneWidget,
    );
  });

  testWidgets('没有结果时导出按钮是禁用的', (WidgetTester tester) async {
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(tester, controller);

    final Finder button = find.ancestor(
      of: find.text('导出字幕'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
  });

  testWidgets('配置 API Key 后可以把识别结果翻译为中文', (WidgetTester tester) async {
    final _FakeSecretStore secrets = _FakeSecretStore()
      ..values[kTranslationApiKeyStorageKey] = 'test-key';
    final AppSettingsRepository settings = AppSettingsRepository(
      preferences: _FakePreferenceStore(),
      secrets: TranslationSecrets(store: secrets),
    );
    final _FakeTranslationProvider provider = _FakeTranslationProvider();
    final TranscribeController controller = build(text: 'hello');
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      settings: settings,
      translationProviderFactory: (_) => provider,
      pickFile: () async => '/tmp/en.wav',
    );

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('translateSubtitle')));
    await tester.pumpAndSettle();
    expect(find.text('发送字幕到第三方服务？'), findsOneWidget);
    await tester.tap(find.text('继续翻译'));
    await tester.pumpAndSettle();

    expect(provider.calls, 1);
    expect(controller.result?.segments.single.translation, '译文：hello');
    expect(find.text('译文：hello'), findsOneWidget);
    expect(find.text('翻译完成：1 段'), findsOneWidget);
  });

  testWidgets('没有 API Key 时翻译入口提示先配置设置', (WidgetTester tester) async {
    final AppSettingsRepository settings = AppSettingsRepository(
      preferences: _FakePreferenceStore(),
      secrets: TranslationSecrets(store: _FakeSecretStore()),
    );
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      settings: settings,
      pickFile: () async => '/tmp/en.wav',
    );

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('translateSubtitle')));
    await tester.pump();

    expect(find.text('请先在设置中保存第三方翻译 API Key'), findsOneWidget);
  });

  testWidgets('切换语言后新识别结果用新语言', (WidgetTester tester) async {
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(tester, controller, pickFile: () async => '/tmp/a.wav');

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('粤语').last);
    await tester.pumpAndSettle();
    expect(controller.language, 'yue');

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(controller.result?.segments.single.language, 'yue');
    expect(find.text('粤语'), findsWidgets); // 下拉里选中的 + 分段行里的语言标签
  });
}

class _FakeTranslationProvider implements TranslationProvider {
  int calls = 0;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) async {
    calls++;
    return texts.map((String text) => '译文：$text').toList();
  }
}

class _NoopBatchTranslationCache extends BatchTranslationCache {
  const _NoopBatchTranslationCache();

  @override
  Future<TranscriptionResult?> read({
    required String mediaPath,
    required TranscriptionResult source,
    required String targetLanguage,
    required String providerScope,
  }) => Future<TranscriptionResult?>.value();

  @override
  Future<void> write({
    required String mediaPath,
    required TranscriptionResult translated,
    required String targetLanguage,
    required String providerScope,
  }) => Future<void>.value();
}

class _FakeBatchQueueStore extends BatchQueueStore {
  _FakeBatchQueueStore([this.snapshot]);

  BatchQueueSnapshot? snapshot;
  int saves = 0;
  int clears = 0;

  @override
  Future<BatchQueueSnapshot?> load() async => snapshot;

  @override
  Future<void> save(BatchQueueSnapshot value) async {
    snapshot = value;
    saves++;
  }

  @override
  Future<void> clear() async {
    snapshot = null;
    clears++;
  }
}

class _MemoryBatchTranslationCache extends BatchTranslationCache {
  _MemoryBatchTranslationCache(this.cachedResult);

  final TranscriptionResult? cachedResult;
  final Map<String, TranscriptionResult> values =
      <String, TranscriptionResult>{};

  @override
  Future<TranscriptionResult?> read({
    required String mediaPath,
    required TranscriptionResult source,
    required String targetLanguage,
    required String providerScope,
  }) => Future<TranscriptionResult?>.value(
    cachedResult ?? values[_key(mediaPath, targetLanguage, providerScope)],
  );

  @override
  Future<void> write({
    required String mediaPath,
    required TranscriptionResult translated,
    required String targetLanguage,
    required String providerScope,
  }) async {
    values[_key(mediaPath, targetLanguage, providerScope)] = translated;
  }

  String _key(String path, String target, String provider) =>
      '$path\n$target\n$provider';
}

class _FakeAutosaveStore implements ProjectAutosaveStore {
  _FakeAutosaveStore([this.project]) : previousSessionUnclean = project != null;

  VsasrProject? project;
  int saves = 0;
  int clears = 0;
  bool sessionActive = false;
  bool previousSessionUnclean;

  @override
  Future<bool> wasPreviousSessionUnclean() async => previousSessionUnclean;

  @override
  Future<void> beginSession() async {
    sessionActive = true;
    previousSessionUnclean = false;
  }

  @override
  Future<void> endSession() async {
    sessionActive = false;
  }

  @override
  Future<VsasrProject?> load() async => project;

  @override
  Future<void> save(VsasrProject value) async {
    project = value;
    saves++;
  }

  @override
  Future<void> clear() async {
    project = null;
    clears++;
  }
}

class _FakePreferenceStore implements PreferenceStore {
  @override
  Future<String?> readString(String key) async => null;

  @override
  Future<bool?> readBool(String key) async => null;

  @override
  Future<int?> readInt(String key) async => null;

  @override
  Future<double?> readDouble(String key) async => null;

  @override
  Future<void> writeString(String key, String value) async {}

  @override
  Future<void> writeBool(String key, bool value) async {}

  @override
  Future<void> writeInt(String key, int value) async {}

  @override
  Future<void> writeDouble(String key, double value) async {}
}

class _FakeSecretStore implements SecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
