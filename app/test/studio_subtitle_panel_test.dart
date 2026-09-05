import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/ui/studio/studio_subtitle_panel.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

void main() {
  testWidgets('无译文的字幕仍显示单句翻译入口', (WidgetTester tester) async {
    final VideoPlaybackController video = VideoPlaybackController(
      backend: const _FakeVideoBackend(),
    );
    addTearDown(video.dispose);

    await tester.pumpWidget(
      _panel(
        video,
        const <Segment>[Segment(text: 'hello', start: 0, end: 1, index: 0)],
        canRetryTranslation: (_) => true,
      ),
    );

    expect(find.text('暂无译文（双击可手动填写）'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('retryTranslation_0')), findsOneWidget);
  });

  testWidgets('单字符字幕的拆分操作会禁用', (WidgetTester tester) async {
    final VideoPlaybackController video = VideoPlaybackController(
      backend: const _FakeVideoBackend(),
    );
    addTearDown(video.dispose);

    await tester.pumpWidget(
      _panel(
        video,
        const <Segment>[Segment(text: '嗯', start: 0, end: 1, index: 0)],
      ),
    );

    final IconButton split = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.call_split),
        matching: find.byType(IconButton),
      ),
    );
    expect(split.onPressed, isNull);
  });

  testWidgets('父组件重建不会丢失正在编辑的字幕文本', (
    WidgetTester tester,
  ) async {
    final VideoPlaybackController video = VideoPlaybackController(
      backend: const _FakeVideoBackend(),
    );
    addTearDown(video.dispose);
    const List<Segment> segments = <Segment>[
      Segment(text: 'hello', start: 0, end: 1, index: 0),
    ];

    await tester.pumpWidget(_panel(video, segments));
    await tester.tap(find.text('hello'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('hello'));
    await tester.pump(const Duration(milliseconds: 100));
    final Finder editor = find.byType(TextField).last;
    await tester.enterText(editor, 'edited text');

    await tester.pumpWidget(_panel(video, segments));
    await tester.pump();

    expect(tester.widget<TextField>(editor).controller?.text, 'edited text');
  });

  testWidgets('结构操作会取消内联编辑，避免重编号后错位保存', (
    WidgetTester tester,
  ) async {
    final VideoPlaybackController video = VideoPlaybackController(
      backend: const _FakeVideoBackend(),
    );
    addTearDown(video.dispose);
    int? deletedIndex;
    const List<Segment> segments = <Segment>[
      Segment(text: 'first', start: 0, end: 1, index: 0),
      Segment(text: 'second', start: 1, end: 2, index: 1),
    ];

    await tester.pumpWidget(
      _panel(
        video,
        segments,
        onDeleteSegment: (int index) => deletedIndex = index,
      ),
    );
    await tester.tap(find.text('second'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('second'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();

    expect(deletedIndex, 0);
    expect(find.byType(TextField), findsOneWidget);
  });
}

Widget _panel(
  VideoPlaybackController video,
  List<Segment> segments, {
  bool Function(Segment segment)? canRetryTranslation,
  ValueChanged<int>? onDeleteSegment,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: StudioSubtitlePanel(
            segments: segments,
            videoController: video,
            canRetryTranslation: canRetryTranslation,
            onDeleteSegment: onDeleteSegment,
          ),
        ),
      ),
    );

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
