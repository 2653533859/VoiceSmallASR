/// 真实 DeepL 英/日视频翻译验收。
///
/// 这是显式手工验收，不属于默认测试集；必须通过
/// `--dart-define-from-file` 传入本地密钥文件，测试不会把密钥写入日志或文件。
/// 运行前需要把模型和 `test_wavs/en.mp4`、`test_wavs/ja.mp4` 放进应用私有模型目录。
///
/// ```bash
/// bash scripts/prepare_translation_acceptance_media.sh "$WAVS" "$WAVS"
/// flutter test integration_test/deepl_acceptance_test.dart -d macos \
///   --dart-define-from-file=/path/to/voicesmallasr-deepl.env
/// ```
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/ui/video_page.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/translation/deepl_provider.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

const List<_TranslationCase> _cases = <_TranslationCase>[
  _TranslationCase(language: 'en', fileName: 'en.mp4'),
  _TranslationCase(language: 'ja', fileName: 'ja.mp4'),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('真实 DeepL 英/日视频生成双语 SRT 并显示视频叠加', (WidgetTester tester) async {
    const String apiKey = String.fromEnvironment('DEEPL_API_KEY');
    if (apiKey.trim().isEmpty) {
      fail('缺少 DEEPL_API_KEY；请用 --dart-define-from-file 传入本地密钥文件');
    }
    const String baseUrl = String.fromEnvironment(
      'DEEPL_API_BASE_URL',
      defaultValue: kDeepLFreeApiBaseUrl,
    );

    final ModelPaths paths = await ModelManager().resolvePaths();
    expect(paths.exists, isTrue, reason: '模型未就绪：${paths.root}');
    final String wavs = p.join(p.dirname(paths.asrModel), 'test_wavs');
    final Directory output = await Directory.systemTemp.createTemp('vsasr-deepl-acceptance-');
    final DeepLTranslationProvider provider = DeepLTranslationProvider(
      apiKey: apiKey,
      baseUrl: baseUrl,
      timeout: const Duration(seconds: 45),
    );

    try {
      for (final _TranslationCase item in _cases) {
        final String videoPath = p.join(wavs, item.fileName);
        expect(File(videoPath).existsSync(), isTrue, reason: '缺少视频素材：$videoPath');

        final TranscribeController transcription = TranscribeController(
          config: AsrConfig(language: item.language),
          offlineMode: true,
        );
        final VideoPlaybackController player = VideoPlaybackController();
        try {
          await transcription.transcribeFile(videoPath);
          await transcription.translateCurrentResult(
            provider,
            targetLanguage: 'ZH',
            batchSize: 10,
            maxRetries: 2,
            retryDelay: const Duration(milliseconds: 500),
          );

          final TranscriptionResult result = transcription.result!;
          final List<Segment> translatedSegments = result.segments
              .where((Segment segment) => segment.text.trim().isNotEmpty)
              .toList();
          expect(translatedSegments, isNotEmpty);
          for (final Segment segment in translatedSegments) {
            expect(segment.translation?.trim(), isNotEmpty);
          }

          final String srt = renderSubtitles(result, 'srt');
          expect(srt, contains('-->'));
          for (final Segment segment in translatedSegments) {
            expect(srt, contains(segment.text.trim()));
            expect(srt, contains(segment.translation!.trim()));
          }
          final File srtFile = File(p.join(output.path, '${item.language}-zh.srt'));
          await srtFile.writeAsString(srt);
          // ignore: avoid_print
          print('${item.language} 双语 SRT：${srtFile.path}');

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 640,
                  height: 600,
                  child: VideoPage(controller: player, transcription: transcription),
                ),
              ),
            ),
          );
          await tester.pump();
          await player.open(videoPath);
          await _waitUntil(
            () => player.duration > const Duration(seconds: 1),
            reason: '${item.fileName} 没有读到视频时长',
          );

          final Segment segment = translatedSegments.first;
          final Duration position = Duration(
            microseconds: (((segment.start + segment.end) / 2) * Duration.microsecondsPerSecond).round(),
          );
          await player.seek(position);
          await _waitUntil(
            () => (player.position.inMicroseconds - position.inMicroseconds).abs() <
                const Duration(milliseconds: 250).inMicroseconds,
            reason: '${item.fileName} 跳转失败',
          );
          await tester.pump();
          expect(find.text('${segment.text}\n${segment.translation}'), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          player.dispose();
          await transcription.shutdown();
          transcription.dispose();
        }
      }
    } finally {
      provider.close();
    }
  });
}

class _TranslationCase {
  const _TranslationCase({required this.language, required this.fileName});

  final String language;
  final String fileName;
}

Future<void> _waitUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed >= timeout) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
