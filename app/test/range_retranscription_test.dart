import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/project/project_file.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_controller.dart';
import 'package:vsasr_app/src/ui/studio/range_retranscription_dialog.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/ui/studio/studio_workspace.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

import 'support/fake_asr.dart';

const source = TranscriptionResult(
  duration: 20,
  segments: [
    Segment(text: '前', start: 0, end: 2, translation: 'before'),
    Segment(text: '旧', start: 4, end: 8, translation: 'old', speaker: 'A'),
    Segment(text: '后', start: 10, end: 12, translation: 'after'),
  ],
);

class RangeDecoder implements AudioDecoder, ResumableChunkedAudioDecoder {
  Duration? startAt;
  int chunks = 0;
  bool closed = false;
  bool empty = false;
  bool cancel = false;
  @override
  Future<Float32List> decodeFile(String path) => throw StateError('不应整段解码');
  @override
  Stream<DecodedAudioChunk> decodeFileChunksFrom(
    String path, {
    required Duration startAt,
    Duration chunkDuration = const Duration(seconds: 10),
  }) async* {
    this.startAt = startAt;
    try {
      if (empty) return;
      for (int i = 0; i < 20; i++) {
        chunks++;
        yield DecodedAudioChunk(Float32List(32000), isLast: false);
      }
    } finally {
      closed = true;
    }
  }
}

Future<TranscribeController> controllerFor(
  RangeDecoder decoder, {
  String text = '新',
  void Function(AsrConfig)? capture,
}) async {
  final controller = TranscribeController(
    decoder: decoder,
    launch:
        ({
          required AsrConfig config,
          required bool allowDownload,
          required ModelProgress onModelProgress,
        }) async {
          capture?.call(config);
          return FakeTranscriber(text: text, language: config.language);
        },
  );
  await controller.loadProject(
    VsasrProject(mediaPath: '/test.mp4', config: AsrConfig(), result: source),
  );
  return controller;
}

void main() {
  test('使用媒体时长补识别字幕末尾之外并可撤销时长更新', () async {
    final controller = await controllerFor(RangeDecoder());
    addTearDown(controller.shutdown);
    final preview = await controller.previewRange(
      start: 25,
      end: 30,
      mediaDuration: 40,
      config: AsrConfig(),
    );
    expect(preview.single.start, 25);
    final editor = SubtitleEditorController(initial: source);
    addTearDown(editor.dispose);
    editor.replaceRange(25, 30, preview, mediaDuration: 40);
    expect(editor.result.duration, 40);
    expect(editor.result.segments.last.end, 30);
    expect(editor.result.segments.first.translation, 'before');
    editor.undo();
    expect(editor.result.duration, 20);
    editor.redo();
    expect(editor.result.duration, 40);
    await expectLater(
      controller.previewRange(
        start: 35,
        end: 45,
        mediaDuration: 40,
        config: AsrConfig(),
      ),
      throwsArgumentError,
    );
  });

  testWidgets('Studio确认替换接入撤销历史', (tester) async {
    final controller = await controllerFor(RangeDecoder());
    final video = VideoPlaybackController(backend: const TestVideoBackend());
    addTearDown(controller.shutdown);
    addTearDown(video.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudioWorkspace(
            controller: controller,
            videoController: video,
            onOpen: () {},
            onOpenProject: () {},
            recentProjects: const [],
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
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studioRetranscribeRange')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rangeStart')), '5');
    await tester.enterText(find.byKey(const Key('rangeEnd')), '7');
    await tester.tap(find.text('识别并预览'));
    await tester.pumpAndSettle();
    expect(controller.result!.segments[1].text, '旧');
    await tester.tap(find.text('确认替换'));
    await tester.pumpAndSettle();
    expect(controller.result!.segments[1].text, '新');
    expect(controller.result!.segments[1].start, 4);
    expect(controller.result!.segments[1].end, 8);
    await tester.tap(find.byKey(const Key('studioUndo')));
    await tester.pumpAndSettle();
    expect(controller.result!.segments[1].translation, 'old');
    await tester.tap(find.byKey(const Key('studioRedo')));
    await tester.pumpAndSettle();
    expect(controller.result!.segments[1].text, '新');
  });

  test('范围扩展、替换清除旧翻译、区外保留并支持一次撤销重做', () {
    final editor = SubtitleEditorController(initial: source);
    addTearDown(editor.dispose);
    expect(editor.resolveRange(5, 7), (start: 4.0, end: 8.0));
    editor.replaceRange(4, 8, const [Segment(text: '新', start: 4.5, end: 7)]);
    expect(editor.result.segments.map((s) => s.text), ['前', '新', '后']);
    expect(editor.result.segments[1].translation, isNull);
    expect(editor.result.segments[1].speaker, isNull);
    expect(editor.result.segments.last.translation, 'after');
    expect(editor.result.segments.map((s) => s.index), [0, 1, 2]);
    editor.undo();
    expect(editor.result.segments[1].translation, 'old');
    expect(editor.canUndo, isFalse);
    editor.redo();
    expect(editor.result.segments[1].text, '新');
  });

  test('空预览、跨界字幕、无效范围不会修改原结果', () {
    final editor = SubtitleEditorController(initial: source);
    addTearDown(editor.dispose);
    final before = editor.result;
    expect(
      () => editor.replaceRange(4, 8, []),
      throwsA(isA<SubtitleEditException>()),
    );
    expect(
      () => editor.replaceRange(5, 7, const [
        Segment(text: 'x', start: 5, end: 7),
      ]),
      throwsA(isA<SubtitleEditException>()),
    );
    expect(
      () => editor.replaceRange(4, 8, const [
        Segment(text: 'x', start: 3, end: 9),
      ]),
      throwsA(isA<SubtitleEditException>()),
    );
    expect(
      () => editor.resolveRange(double.nan, 7),
      throwsA(isA<SubtitleEditException>()),
    );
    expect(editor.result, same(before));
    expect(editor.canUndo, isFalse);
  });

  test('无字幕间隙可以插入新识别结果', () {
    final editor = SubtitleEditorController(initial: source);
    addTearDown(editor.dispose);
    editor.replaceRange(2, 4, const [
      Segment(text: '补漏', start: 2.5, end: 3.5),
    ]);
    expect(editor.result.segments.map((s) => s.text), ['前', '补漏', '旧', '后']);
  });

  test('只解码选区、提前关闭流、时间及token平移且配置与原结果不变', () async {
    final decoder = RangeDecoder();
    AsrConfig? used;
    final controller = await controllerFor(
      decoder,
      capture: (config) => used = config,
    );
    addTearDown(controller.shutdown);
    final preview = await controller.previewRange(
      start: 4,
      end: 7,
      config: AsrConfig(language: 'ja', inputGainDb: 6),
    );
    expect(decoder.startAt, const Duration(seconds: 4));
    expect(decoder.chunks, 2);
    expect(decoder.closed, isTrue);
    expect(preview.single.start, 4);
    expect(preview.single.end, 7);
    expect(preview.single.words.single.start, 4);
    expect(preview.single.words.single.end, 7);
    expect(used!.language, 'ja');
    expect(used!.inputGainDb, 6);
    expect(controller.config.inputGainDb, 0);
    expect(controller.result, same(source));
    expect(controller.busy, isFalse);
    expect(controller.scheduler.activeLeases, isEmpty);
  });

  test('无音频及取消都释放任务且保留原字幕', () async {
    final decoder = RangeDecoder()..empty = true;
    final controller = await controllerFor(decoder);
    addTearDown(controller.shutdown);
    await expectLater(
      controller.previewRange(start: 4, end: 8, config: AsrConfig()),
      throwsStateError,
    );
    expect(controller.busy, isFalse);
    decoder.empty = false;
    await expectLater(
      controller.previewRange(
        start: 4,
        end: 8,
        config: AsrConfig(),
        isCancelled: () => decoder.chunks > 0,
      ),
      throwsStateError,
    );
    expect(decoder.closed, isTrue);
    expect(controller.result, same(source));
    expect(controller.busy, isFalse);
    expect(controller.scheduler.activeLeases, isEmpty);
  });

  testWidgets('预览不改原文，确认才返回替换结果，调整参数使预览失效', (tester) async {
    final controller = await controllerFor(RangeDecoder());
    addTearDown(controller.shutdown);
    RangeReplacement? replacement;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                replacement = await showDialog<RangeReplacement>(
                  context: context,
                  builder: (_) => RangeRetranscriptionDialog(
                    controller: controller,
                    initial: source,
                    position: 4,
                    mediaDuration: 40,
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
    await tester.enterText(find.byKey(const Key('rangeEnd')), '8');
    await tester.tap(find.text('识别并预览'));
    await tester.pumpAndSettle();
    expect(controller.result, same(source));
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认替换'))
          .onPressed,
      isNotNull,
    );
    await tester.enterText(find.byKey(const Key('rangeEnd')), '29');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认替换'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('识别并预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认替换'));
    await tester.pumpAndSettle();
    expect(replacement!.start, 4);
    expect(replacement!.end, 29);
    expect(controller.result, same(source));
  });
}

class TestVideoBackend implements VideoPlayerBackend {
  const TestVideoBackend();
  @override
  Widget buildVideo({VideoOverlayBuilder? overlayBuilder}) => const SizedBox();
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> open(String path) async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setRate(double rate) async {}
}
