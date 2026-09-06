import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/waveform.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_controller.dart';
import 'package:vsasr_app/src/ui/studio/waveform_timeline_dialog.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

class Backend implements VideoPlayerBackend {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final playingChanges = StreamController<bool>.broadcast(sync: true);
  bool isPlaying = false;
  Duration? lastSeek;
  @override
  Stream<Duration> get position => positions.stream;
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<bool> get playing => playingChanges.stream;
  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    positions.add(position);
  }

  @override
  Future<void> open(String path) async {}
  @override
  Future<void> playOrPause() async {
    isPlaying = !isPlaying;
    playingChanges.add(isPlaying);
  }

  @override
  Future<void> setRate(double rate) async {}
  @override
  Widget buildVideo({VideoOverlayBuilder? overlayBuilder}) => const SizedBox();
  @override
  Future<void> dispose() async {
    await positions.close();
    await playingChanges.close();
  }
}

const initial = TranscriptionResult(
  duration: 60,
  segments: [
    Segment(text: '第一句字幕', start: 2, end: 8, translation: 'first'),
    Segment(text: '第二句字幕', start: 10, end: 18),
  ],
);
Future<WaveformData> loader({
  required String path,
  required double start,
  required double duration,
  bool Function()? isCancelled,
}) async => WaveformData(
  Float32List.fromList(List.generate(600, (i) => (i % 31) / 40)),
  duration,
);

void main() {
  setUpAll(() async {
    final fontPath = Platform.environment['VSASR_WAVEFORM_FONT'];
    if (fontPath != null) {
      final font = FontLoader('WaveformQA')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(fontPath).readAsBytes()),
          ),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  testWidgets('拖选识别范围、拖边界提交一次且可撤销，拒绝重叠', (tester) async {
    final backend = Backend();
    final player = VideoPlaybackController(backend: backend);
    final editor = SubtitleEditorController(initial: initial);
    addTearDown(player.dispose);
    addTearDown(editor.dispose);
    await player.open('/test');
    WaveformSelection? selection;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          fontFamily: Platform.environment['VSASR_WAVEFORM_FONT'] == null
              ? null
              : 'WaveformQA',
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selection = await showDialog<WaveformSelection>(
                  context: context,
                  builder: (_) => WaveformTimelineDialog(
                    player: player,
                    path: '/test',
                    duration: 60,
                    result: () => editor.result,
                    loader: loader,
                    onTimingChanged: (i, start, end) =>
                        editor.updateSegment(i, start: start, end: end),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final wave = find.byKey(const Key('waveformSelection'));
    final width = tester.getSize(wave).width;
    await tester.drag(
      find.byKey(const Key('waveformBoundary-0-end')),
      Offset(width / 30, 0),
    );
    await tester.pumpAndSettle();
    expect(editor.result.segments.first.end, closeTo(9, .05));
    expect(editor.canUndo, isTrue);
    editor.undo();
    expect(editor.result.segments.first.end, 8);
    expect(editor.canUndo, isFalse);
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('waveformBoundary-0-end')),
      Offset(width / 30 * 4, 0),
    );
    await tester.pumpAndSettle();
    expect(editor.result.segments.first.end, 8);
    expect(find.textContaining('重叠'), findsOneWidget);
    final origin = tester.getTopLeft(wave);
    await tester.dragFrom(
      origin + Offset(width * .2, 50),
      Offset(width * .3, 0),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('waveformRecognize')));
    await tester.pumpAndSettle();
    expect(selection!.start, closeTo(6, .05));
    expect(selection!.end, closeTo(15, .05));
  });

  testWidgets('循环选区在实际到达末尾后跳回，关闭后不再循环', (tester) async {
    final backend = Backend();
    final player = VideoPlaybackController(backend: backend);
    addTearDown(player.dispose);
    await player.open('/test');
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          fontFamily: Platform.environment['VSASR_WAVEFORM_FONT'] == null
              ? null
              : 'WaveformQA',
        ),
        home: WaveformTimelineDialog(
          player: player,
          path: '/test',
          duration: 60,
          result: () => initial,
          loader: loader,
          onTimingChanged: (_, _, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final wave = find.byKey(const Key('waveformSelection'));
    final width = tester.getSize(wave).width;
    await tester.dragFrom(
      tester.getTopLeft(wave) + Offset(width * .2, 50),
      Offset(width * .3, 0),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('waveformLoop')));
    await tester.pumpAndSettle();
    expect(backend.isPlaying, isTrue);
    backend.positions.add(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(backend.lastSeek!.inMilliseconds, closeTo(6000, 50));
    await tester.pumpWidget(const SizedBox());
    backend.positions.add(const Duration(seconds: 20));
    expect(player.position, const Duration(seconds: 20));
  });

  testWidgets('切换窗口丢弃迟到结果，关闭会取消未完成加载', (tester) async {
    final player = VideoPlaybackController(backend: Backend());
    addTearDown(player.dispose);
    await player.open('/test');
    final pending = <Completer<WaveformData>>[];
    final cancelled = <bool Function()>[];
    Future<WaveformData> delayed({
      required String path,
      required double start,
      required double duration,
      bool Function()? isCancelled,
    }) {
      final next = Completer<WaveformData>();
      pending.add(next);
      cancelled.add(isCancelled!);
      return next.future;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: WaveformTimelineDialog(
          player: player,
          path: '/test',
          duration: 90,
          result: () => initial,
          loader: delayed,
          onTimingChanged: (_, _, _) {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('waveformNext')));
    await tester.pump();
    expect(cancelled.first(), isTrue);
    pending.first.complete(WaveformData(Float32List(600), 30));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(cancelled.last(), isTrue);
    pending.last.complete(WaveformData(Float32List(600), 30));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1100, 700)]) {
    testWidgets('波形时间轴布局 $size 无溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = VideoPlaybackController(backend: Backend());
      addTearDown(player.dispose);
      await player.open('/test');
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: Platform.environment['VSASR_WAVEFORM_FONT'] == null
                ? null
                : 'WaveformQA',
          ),
          home: WaveformTimelineDialog(
            player: player,
            path: '/test',
            duration: 60,
            result: () => initial,
            loader: loader,
            onTimingChanged: (_, _, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (Platform.environment['VSASR_WAVEFORM_GOLDEN'] == '1') {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('/tmp/waveform-${size.width.toInt()}.png'),
        );
      }
    });
  }
}
