import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/ui/video_page.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/subtitles/subtitle_style.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/hard_subtitle_encoder.dart';
import 'package:vsasr_app/src/video/video_subtitle_cache.dart';

import 'support/fake_asr.dart';

void main() {
  testWidgets('载入已转写视频、显示当前字幕并可点击跳转', (WidgetTester tester) async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'vsasr_video_test',
    );
    final String videoPath = '${workspace.path}/movie.mp4';
    final String nextVideoPath = '${workspace.path}/next.mp4';
    File(videoPath).writeAsStringSync('video');
    File(nextVideoPath).writeAsStringSync('next video');
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
    final VideoPlaybackController video = VideoPlaybackController(
      backend: backend,
    );
    final _FakeTranslationProvider translation = _FakeTranslationProvider();
    String? savedFileName;
    String? savedContent;
    String? hardSubtitleFileName;
    final _FakeHardSubtitleEncoder hardSubtitleEncoder =
        _FakeHardSubtitleEncoder();
    addTearDown(() async {
      video.dispose();
      await transcription.shutdown();
      workspace.deleteSync(recursive: true);
    });
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await transcription.transcribeFile(videoPath);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoPage(
            controller: video,
            transcription: transcription,
            pickFile: () async => videoPath,
            pickFiles: () async => <String>[nextVideoPath],
            pickSubtitleFile: () async => SubtitleFileData(
              name: 'external.srt',
              bytes: Uint8List.fromList(
                utf8.encode('1\n00:00:00,000 --> 00:00:01,000\n外部字幕\n'),
              ),
            ),
            saveSubtitleFile: (String name, String content) async {
              savedFileName = name;
              savedContent = content;
              return '/tmp/$name';
            },
            saveHardSubtitleVideo: (String name) async {
              hardSubtitleFileName = name;
              return '${workspace.path}/hard-subtitles.mp4';
            },
            hardSubtitleEncoder: hardSubtitleEncoder,
            translationProviderResolver: () async => translation,
            subtitleCache: VideoSubtitleCache(rootDirectory: workspace),
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

    await tester.tap(find.byKey(const Key('videoTranslationToggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('译文：字幕第一条'), findsNothing);
    await tester.tap(find.byKey(const Key('videoSubtitlesToggle')));
    await tester.pumpAndSettle();
    expect(find.text('字幕第一条'), findsNothing);
    await tester.tap(find.byKey(const Key('videoSubtitlesToggle')));
    await tester.tap(find.byKey(const Key('videoTranslationToggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('译文：字幕第一条'), findsNWidgets(2));

    await tester.tap(find.byKey(const Key('videoImportSubtitle')));
    await tester.pumpAndSettle();
    expect(transcription.result?.segments.single.text, '外部字幕');
    expect(find.text('外部字幕'), findsNWidgets(2));
    expect(find.textContaining('已加载字幕：external.srt'), findsOneWidget);

    await tester.tap(find.byKey(const Key('videoExportSubtitles')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('videoExportFormat-srt')));
    await tester.pumpAndSettle();
    expect(savedFileName, 'movie.srt');
    expect(savedContent, contains('外部字幕'));

    await tester.tap(find.byKey(const Key('videoSubtitleStyle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subtitleStyleFontSize')), findsOneWidget);
    await tester.tap(find.byKey(const Key('saveSubtitleStyle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('saveSubtitleStyle')), findsNothing);

    await tester.tap(find.byKey(const Key('videoBurnSubtitles')));
    await tester.pumpAndSettle();
    expect(hardSubtitleFileName, 'movie_hard_subtitles.mp4');
    expect(hardSubtitleEncoder.calls, 1);

    await tester.tap(find.byKey(const Key('videoAddPlaylist')));
    await tester.pumpAndSettle();
    expect(find.text('next.mp4'), findsOneWidget);
    expect(find.byKey(const Key('videoPlaylist')), findsOneWidget);

    backend.emitDuration(const Duration(seconds: 2));
    backend.emitPosition(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(backend.openedPath, nextVideoPath);
    expect(backend.playOrPauseCalls, 1);
  });

  testWidgets('翻译不可用时播放列表状态保留警告', (WidgetTester tester) async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'vsasr_video_warning_test',
    );
    final String videoPath = '${workspace.path}/movie.mp4';
    File(videoPath).writeAsStringSync('video');
    writeFakeModel(workspace.path);
    final TranscribeController transcription = TranscribeController(
      decoder: FakeDecoder(samples: kSampleRate),
      models: ModelManager(root: workspace.path),
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async => FakeTranscriber(
            language: 'en',
            liveSegments: const <Segment>[
              Segment(
                text: 'hello',
                start: 0,
                end: 1,
                language: 'en',
                index: 0,
              ),
            ],
          ),
    );
    final VideoPlaybackController video = VideoPlaybackController(
      backend: _FakeVideoBackend(),
    );
    addTearDown(() async {
      video.dispose();
      await transcription.shutdown();
      workspace.deleteSync(recursive: true);
    });
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoPage(
            controller: video,
            transcription: transcription,
            pickFile: () async => videoPath,
            translationProviderResolver: () async => null,
            subtitleCache: VideoSubtitleCache(rootDirectory: workspace),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开视频'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('videoTranslationToggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续翻译'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('未配置翻译 API Key'), findsOneWidget);
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

class _FakeHardSubtitleEncoder implements HardSubtitleEncoder {
  int calls = 0;

  @override
  Future<void> encode({
    required String inputPath,
    required String outputPath,
    required TranscriptionResult result,
    required SubtitleStyle style,
    HardSubtitleProgress? onProgress,
  }) async {
    calls++;
    onProgress?.call(0.5);
    onProgress?.call(1.0);
  }
}

class _FakeVideoBackend implements VideoPlayerBackend {
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<Duration> _durations =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<bool> _playing = StreamController<bool>.broadcast(
    sync: true,
  );

  Duration? lastSeek;
  String? openedPath;
  int playOrPauseCalls = 0;

  @override
  Widget buildVideo() => const SizedBox();

  @override
  Stream<Duration> get position => _positions.stream;

  @override
  Stream<Duration> get duration => _durations.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Future<void> open(String path) async => openedPath = path;

  @override
  Future<void> playOrPause() async => playOrPauseCalls++;

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
