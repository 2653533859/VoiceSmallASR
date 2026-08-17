import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/ui/video_page.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

import 'support/fake_asr.dart';

void main() {
  testWidgets('载入已转写视频、显示当前字幕并可点击跳转', (WidgetTester tester) async {
    final Directory workspace = Directory.systemTemp.createTempSync('vsasr_video_test');
    final String videoPath = '${workspace.path}/movie.mp4';
    writeFakeModel(workspace.path);
    final TranscribeController transcription = TranscribeController(
      decoder: FakeDecoder(samples: 2 * kSampleRate),
      models: ModelManager(root: workspace.path),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => FakeTranscriber(language: config.language, text: '字幕第一条'),
    );
    final _FakeVideoBackend backend = _FakeVideoBackend();
    final VideoPlaybackController video = VideoPlaybackController(backend: backend);
    final _FakeTranslationProvider translation = _FakeTranslationProvider();
    addTearDown(() async {
      video.dispose();
      await transcription.shutdown();
      workspace.deleteSync(recursive: true);
    });

    await transcription.transcribeFile(videoPath);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoPage(
            controller: video,
            transcription: transcription,
            pickFile: () async => videoPath,
            pickSubtitleFile: () async => SubtitleFileData(
              name: 'external.srt',
              bytes: Uint8List.fromList(
                utf8.encode('1\n00:00:00,000 --> 00:00:01,000\n外部字幕\n'),
              ),
            ),
            translationProviderResolver: () async => translation,
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开视频'));
    await tester.pump();
    backend.emitDuration(const Duration(seconds: 2));
    backend.emitPosition(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.text('字幕第一条'), findsNWidgets(2));
    await tester.tap(find.text('字幕第一条').last);
    expect(backend.lastSeek, Duration.zero);

    await tester.tap(find.byKey(const Key('videoTranslateSubtitle')));
    await tester.pumpAndSettle();
    expect(find.text('发送字幕到第三方服务？'), findsOneWidget);
    await tester.tap(find.text('继续翻译'));
    await tester.pumpAndSettle();
    expect(find.textContaining('译文：字幕第一条'), findsNWidgets(2));
    expect(translation.calls, 1);

    await tester.tap(find.byKey(const Key('videoImportSubtitle')));
    await tester.pumpAndSettle();
    expect(transcription.result?.segments.single.text, '外部字幕');
    expect(find.text('外部字幕'), findsNWidgets(2));
    expect(find.textContaining('已加载字幕：external.srt'), findsOneWidget);
  });
}

class _FakeTranslationProvider implements TranslationProvider {
  int calls = 0;
  String? targetLanguage;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) async {
    calls++;
    targetLanguage = to;
    return texts.map((String text) => '译文：$text').toList();
  }
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

  void emitPosition(Duration value) => _positions.add(value);

  void emitDuration(Duration value) => _durations.add(value);
}
