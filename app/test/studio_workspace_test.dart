import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/ui/studio/studio_workspace.dart';
import 'package:vsasr_app/src/ui/studio/studio_subtitle_panel.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

void main() {
  for (final Size size in <Size>[const Size(390, 844), const Size(640, 480)]) {
    testWidgets('工作台在 $size 下校对工具不溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final TranscribeController transcription = TranscribeController()
        ..applyImportedResult(
          const TranscriptionResult(
            duration: 2,
            segments: <Segment>[
              Segment(text: '测试字幕', start: 0, end: 2, index: 0),
            ],
          ),
        );
      final VideoPlaybackController video = VideoPlaybackController(
        backend: const _FakeVideoBackend(),
      );
      addTearDown(video.dispose);
      addTearDown(transcription.shutdown);
      await tester.pumpWidget(
        _workspace(
          transcription: transcription,
          video: video,
          resolver: () async => null,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('studioReplace')), findsOneWidget);
    });
  }

  testWidgets('工作台编辑、撤销重做和删除后恢复保留项目结果', (tester) async {
    final TranscribeController transcription = TranscribeController()
      ..applyImportedResult(
        const TranscriptionResult(
          duration: 2,
          segments: <Segment>[
            Segment(
              text: '原文',
              start: 0,
              end: 1,
              index: 0,
              translation: 'original',
            ),
            Segment(text: '第二句', start: 1, end: 2, index: 1),
          ],
        ),
      );
    final VideoPlaybackController video = VideoPlaybackController(
      backend: const _FakeVideoBackend(),
    );
    addTearDown(video.dispose);
    addTearDown(transcription.shutdown);
    await tester.pumpWidget(
      _workspace(
        transcription: transcription,
        video: video,
        resolver: () async => null,
      ),
    );
    tester
        .widget<StudioSubtitlePanel>(find.byType(StudioSubtitlePanel))
        .onUpdateSegment!(0, text: '修改后的原文');
    await tester.pump();
    expect(transcription.result!.segments.first.text, '修改后的原文');
    expect(transcription.result!.segments.first.translation, isNull);
    // 无关通知不能清空编辑历史。
    transcription.notifyListeners();
    await tester.pump();
    await tester.tap(find.byKey(const Key('studioUndo')));
    await tester.pump();
    expect(transcription.result!.segments.first.translation, 'original');
    await tester.tap(find.byKey(const Key('studioRedo')));
    await tester.pump();
    expect(transcription.result!.segments.first.text, '修改后的原文');
    tester
        .widget<StudioSubtitlePanel>(find.byType(StudioSubtitlePanel))
        .onDeleteSegment!(0);
    await tester.pump();
    expect(transcription.result!.segments, hasLength(1));
    await tester.tap(find.byKey(const Key('studioUndo')));
    await tester.pump();
    expect(transcription.projectSnapshot.result.segments.first.text, '修改后的原文');
  });

  testWidgets('搜索替换可撤销且阅读速度检查可在工作台打开', (tester) async {
    final TranscribeController transcription = TranscribeController()
      ..applyImportedResult(
        const TranscriptionResult(
          duration: 1,
          segments: <Segment>[
            Segment(text: '这里是一条需要检查阅读速度的长字幕文本', start: 0, end: 1, index: 0),
          ],
        ),
      );
    final VideoPlaybackController video = VideoPlaybackController(
      backend: const _FakeVideoBackend(),
    );
    addTearDown(video.dispose);
    addTearDown(transcription.shutdown);
    await tester.pumpWidget(
      _workspace(
        transcription: transcription,
        video: video,
        resolver: () async => null,
      ),
    );
    await tester.tap(find.byKey(const Key('studioReplace')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('studioReplaceSearch')), '这里');
    await tester.enterText(find.byKey(const Key('studioReplaceValue')), '那里');
    await tester.tap(find.byKey(const Key('studioReplaceConfirm')));
    await tester.pumpAndSettle();
    expect(transcription.result!.text, startsWith('那里'));
    await tester.tap(find.byKey(const Key('studioUndo')));
    await tester.pump();
    expect(transcription.result!.text, startsWith('这里'));
    await tester.tap(find.byKey(const Key('studioReadingSpeed')));
    await tester.pumpAndSettle();
    expect(find.textContaining('字/秒'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('单句翻译使用已保存的目标语言并释放 provider', (WidgetTester tester) async {
    final AppSettingsRepository settings = AppSettingsRepository(
      preferences: _FakePreferenceStore(),
    );
    await settings.saveTranslationApiSettings(
      const TranslationApiSettings(targetLanguage: 'ja'),
    );
    final TranscribeController transcription = TranscribeController()
      ..applyImportedResult(
        const TranscriptionResult(
          duration: 1,
          language: 'en',
          segments: <Segment>[
            Segment(text: 'hello', start: 0, end: 1, index: 0),
          ],
        ),
      );
    final VideoPlaybackController video = VideoPlaybackController(
      backend: const _FakeVideoBackend(),
    );
    final _RecordingProvider provider = _RecordingProvider();
    addTearDown(video.dispose);
    addTearDown(transcription.shutdown);

    await tester.pumpWidget(
      _workspace(
        transcription: transcription,
        video: video,
        settings: settings,
        resolver: () async => provider,
      ),
    );

    final IconButton retry = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('retryTranslation_0')),
    );
    expect(retry.onPressed, isNotNull);
    retry.onPressed!();
    await tester.pumpAndSettle();

    expect(provider.targets, <String>['ja']);
    expect(provider.closed, isTrue);
    expect(transcription.result?.segments.single.translation, 'ja:hello');
  });

  testWidgets('编辑字幕期间会丢弃迟到的单句译文', (WidgetTester tester) async {
    final TranscribeController transcription = TranscribeController()
      ..applyImportedResult(
        const TranscriptionResult(
          duration: 2,
          language: 'en',
          segments: <Segment>[
            Segment(text: 'first', start: 0, end: 1, index: 0),
            Segment(text: 'second', start: 1, end: 2, index: 1),
          ],
        ),
      );
    final VideoPlaybackController video = VideoPlaybackController(
      backend: const _FakeVideoBackend(),
    );
    final _RecordingProvider provider = _RecordingProvider(
      response: Completer<List<String>>(),
    );
    addTearDown(video.dispose);
    addTearDown(transcription.shutdown);

    await tester.pumpWidget(
      _workspace(
        transcription: transcription,
        video: video,
        settings: AppSettingsRepository(preferences: _FakePreferenceStore()),
        resolver: () async => provider,
      ),
    );

    tester
        .widget<IconButton>(
          find.byKey(const ValueKey<String>('retryTranslation_1')),
        )
        .onPressed!();
    await tester.pump();
    expect(provider.targets, <String>['zh-CN']);
    tester
        .widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.delete_outline).first,
            matching: find.byType(IconButton),
          ),
        )
        .onPressed!();
    await tester.pump();
    provider.response!.complete(<String>['迟到译文']);
    await tester.pumpAndSettle();

    expect(transcription.result?.segments, hasLength(1));
    expect(transcription.result?.segments.single.text, 'second');
    expect(transcription.result?.segments.single.translation, isNull);
  });
}

Widget _workspace({
  required TranscribeController transcription,
  required VideoPlaybackController video,
  required Future<TranslationProvider?> Function() resolver,
  AppSettingsRepository? settings,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 1200,
      height: 800,
      child: StudioWorkspace(
        controller: transcription,
        videoController: video,
        onOpen: () {},
        onOpenProject: () {},
        recentProjects: const <String>[],
        onOpenRecentProject: (_) {},
        onSaveProject: () {},
        onExport: () {},
        onEdit: () {},
        onTranslate: () {},
        onDiarize: () {},
        onImport: () {},
        onBatch: () {},
        onDiagnostics: () {},
        onHistory: () {},
        historyAvailable: false,
        settings: settings,
        translationProviderResolver: resolver,
      ),
    ),
  ),
);

class _RecordingProvider implements ClosableTranslationProvider {
  _RecordingProvider({this.response});

  final Completer<List<String>>? response;
  final List<String> targets = <String>[];
  bool closed = false;

  @override
  void close() {
    closed = true;
  }

  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) {
    targets.add(to);
    return response?.future ??
        Future<List<String>>.value(
          texts.map((String text) => '$to:$text').toList(growable: false),
        );
  }
}

class _FakeVideoBackend implements VideoPlayerBackend {
  const _FakeVideoBackend();

  @override
  Widget buildVideo({VideoOverlayBuilder? overlayBuilder}) => const SizedBox();

  @override
  Stream<Duration> get duration => const Stream<Duration>.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<void> open(String path) async {}

  @override
  Stream<bool> get playing => const Stream<bool>.empty();

  @override
  Future<void> playOrPause() async {}

  @override
  Stream<Duration> get position => const Stream<Duration>.empty();

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setRate(double rate) async {}
}

class _FakePreferenceStore implements PreferenceStore {
  final Map<String, String> strings = <String, String>{};
  final Map<String, bool> bools = <String, bool>{};
  final Map<String, int> ints = <String, int>{};
  final Map<String, double> doubles = <String, double>{};

  @override
  Future<bool?> readBool(String key) async => bools[key];

  @override
  Future<double?> readDouble(String key) async => doubles[key];

  @override
  Future<int?> readInt(String key) async => ints[key];

  @override
  Future<String?> readString(String key) async => strings[key];

  @override
  Future<void> writeBool(String key, bool value) async {
    bools[key] = value;
  }

  @override
  Future<void> writeDouble(String key, double value) async {
    doubles[key] = value;
  }

  @override
  Future<void> writeInt(String key, int value) async {
    ints[key] = value;
  }

  @override
  Future<void> writeString(String key, String value) async {
    strings[key] = value;
  }
}
