import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_page.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

void main() {
  const TranscriptionResult result = TranscriptionResult(
    duration: 3.0,
    segments: <Segment>[
      Segment(text: '第一句', start: 0.0, end: 1.0),
      Segment(text: '第二句', start: 1.0, end: 2.0),
    ],
  );

  testWidgets('编辑文本后可以撤销、重做并保存', (WidgetTester tester) async {
    TranscriptionResult? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleEditorPage(initialResult: result, onSave: (TranscriptionResult value) => saved = value),
      ),
    );

    await tester.enterText(find.byKey(const Key('subtitleText_0')), '改好的句子');
    await tester.tap(find.byKey(const Key('subtitleApply_0')));
    await tester.pump();
    expect(find.text('改好的句子'), findsOneWidget);

    await tester.tap(find.byKey(const Key('subtitleUndo')));
    await tester.pump();
    expect(find.text('第一句'), findsOneWidget);
    await tester.tap(find.byKey(const Key('subtitleRedo')));
    await tester.pump();
    expect(find.text('改好的句子'), findsOneWidget);

    await tester.tap(find.byKey(const Key('subtitleSave')));
    await tester.pumpAndSettle();
    expect(saved?.segments.first.text, '改好的句子');
  });

  testWidgets('编辑器可以通过播放器定位到字幕开始位置', (WidgetTester tester) async {
    final _FakeVideoBackend backend = _FakeVideoBackend();
    final VideoPlaybackController player = VideoPlaybackController(backend: backend);
    addTearDown(player.dispose);
    await player.open('test.mp4');

    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleEditorPage(initialResult: result, player: player, onSave: (_) {}),
      ),
    );
    await tester.tap(find.byKey(const Key('subtitleSeek_1')));
    await tester.pump();
    expect(backend.lastSeek, const Duration(seconds: 1));
  });

  testWidgets('编辑器支持合并和拆分入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SubtitleEditorPage(initialResult: result, onSave: (_) {})),
    );

    await tester.tap(find.byKey(const Key('subtitleMerge_0')));
    await tester.pump();
    expect(find.byKey(const Key('subtitleText_1')), findsNothing);
    expect(find.text('第一句 第二句'), findsOneWidget);

    await tester.tap(find.byKey(const Key('subtitleUndo')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('subtitleSplit_0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subtitleSplitConfirm')));
    await tester.pump();
    expect(find.byKey(const Key('subtitleText_1')), findsOneWidget);
  });

  testWidgets('编辑器支持批量偏移字幕时间', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleEditorPage(initialResult: result, onSave: (_) {}),
      ),
    );

    await tester.tap(find.byKey(const Key('subtitleOffset')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('subtitleOffsetSeconds')),
      '0.5',
    );
    await tester.tap(find.byKey(const Key('subtitleOffsetConfirm')));
    await tester.pump();

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('subtitleStart_0')))
          .controller
          ?.text,
      '0.500',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('subtitleEnd_1')))
          .controller
          ?.text,
      '2.500',
    );
  });
}

class _FakeVideoBackend implements VideoPlayerBackend {
  final StreamController<Duration> _positions = StreamController<Duration>.broadcast(sync: true);
  final StreamController<Duration> _durations = StreamController<Duration>.broadcast(sync: true);
  final StreamController<bool> _playing = StreamController<bool>.broadcast(sync: true);
  Duration? lastSeek;

  @override
  Widget buildVideo() => const SizedBox();

  @override
  Stream<Duration> get position => _positions.stream;

  @override
  Stream<Duration> get duration => _durations.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Future<void> open(String path) async {}

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> seek(Duration position) async => lastSeek = position;

  @override
  Future<void> dispose() async {
    await Future.wait<void>(<Future<void>>[
      _positions.close(),
      _durations.close(),
      _playing.close(),
    ]);
  }
}
