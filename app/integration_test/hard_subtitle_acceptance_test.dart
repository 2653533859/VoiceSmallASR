/// 真实硬字幕视频编码验收：桌面使用 FFmpeg，Android 使用 MediaCodec。
/// Android 的 AAC 音轨会直通，系统可解码的非 AAC 音轨会先转成 AAC。
///
/// 默认跳过，不依赖系统 FFmpeg。运行时提供一个本地视频文件：
///
/// ```bash
/// VSASR_HARD_SUBTITLE_TEST_VIDEO=/path/to/input.mp4 \
/// flutter test integration_test/hard_subtitle_acceptance_test.dart -d macos
/// ```
///
/// 也可以一次验收多个输入，使用 `|` 分隔路径：
///
/// ```bash
/// VSASR_HARD_SUBTITLE_TEST_VIDEOS=/path/a.mp4\|/path/b.webm \
/// flutter test integration_test/hard_subtitle_acceptance_test.dart -d macos
/// ```
///
/// Android 使用系统 MediaCodec；输入文件必须是应用可读的本地路径：
///
/// ```bash
/// VSASR_HARD_SUBTITLE_TEST_VIDEO=/path/in/app-readable-storage/input.mp4 \
/// flutter test integration_test/hard_subtitle_acceptance_test.dart -d android-device \
///   --dart-define=VSASR_HARD_SUBTITLE_TEST_VIDEO=/path/in/app-readable-storage/input.mp4
/// ```
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_style.dart';
import 'package:vsasr_app/src/video/hard_subtitle_encoder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('真实编码生成带字幕的 mp4', () async {
    final List<String> inputs = _testInputs();
    if (inputs.isEmpty) {
      markTestSkipped(
        '未提供 VSASR_HARD_SUBTITLE_TEST_VIDEO 或 '
        'VSASR_HARD_SUBTITLE_TEST_VIDEOS',
      );
      return;
    }
    final Directory outputDirectory = await Directory.systemTemp.createTemp(
      'vsasr-hard-subtitle-acceptance-',
    );
    addTearDown(() async {
      if (outputDirectory.existsSync()) {
        await outputDirectory.delete(recursive: true);
      }
    });

    final HardSubtitleEncoder encoder = Platform.isAndroid
        ? AndroidHardSubtitleEncoder()
        : FfmpegHardSubtitleEncoder();
    for (int index = 0; index < inputs.length; index++) {
      final String output = '${outputDirectory.path}/output-$index.mp4';
      await encoder.encode(
        inputPath: inputs[index],
        outputPath: output,
        result: const TranscriptionResult(
          duration: 2,
          segments: <Segment>[
            Segment(text: '硬字幕验收', start: 0, end: 2, index: 0),
          ],
        ),
        style: const SubtitleStyle(),
      );
      expect(File(output).existsSync(), isTrue, reason: inputs[index]);
      expect(
        await File(output).length(),
        greaterThan(1024),
        reason: inputs[index],
      );
    }
  });
}

List<String> _testInputs() {
  const String definedVideos = String.fromEnvironment(
    'VSASR_HARD_SUBTITLE_TEST_VIDEOS',
  );
  const String definedVideo = String.fromEnvironment(
    'VSASR_HARD_SUBTITLE_TEST_VIDEO',
  );
  final String? environmentVideos =
      Platform.environment['VSASR_HARD_SUBTITLE_TEST_VIDEOS'];
  final String? environmentVideo =
      Platform.environment['VSASR_HARD_SUBTITLE_TEST_VIDEO'];
  final String configured = definedVideos.trim().isNotEmpty
      ? definedVideos
      : definedVideo.trim().isNotEmpty
      ? definedVideo
      : (environmentVideos?.trim().isNotEmpty == true
            ? environmentVideos!
            : environmentVideo ?? '');
  return configured
      .split('|')
      .map((String path) => path.trim())
      .where((String path) => path.isNotEmpty)
      .toList(growable: false);
}
