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
    const String definedInput = String.fromEnvironment(
      'VSASR_HARD_SUBTITLE_TEST_VIDEO',
    );
    final String? input =
        (definedInput.trim().isNotEmpty
                ? definedInput
                : Platform.environment['VSASR_HARD_SUBTITLE_TEST_VIDEO'])
            ?.trim();
    if (input == null || input.isEmpty) {
      markTestSkipped('未提供 VSASR_HARD_SUBTITLE_TEST_VIDEO');
      return;
    }
    final Directory outputDirectory = await Directory.systemTemp.createTemp(
      'vsasr-hard-subtitle-acceptance-',
    );
    final String output = '${outputDirectory.path}/output.mp4';
    addTearDown(() async {
      if (outputDirectory.existsSync()) {
        await outputDirectory.delete(recursive: true);
      }
    });

    final HardSubtitleEncoder encoder = Platform.isAndroid
        ? AndroidHardSubtitleEncoder()
        : FfmpegHardSubtitleEncoder();
    await encoder.encode(
      inputPath: input,
      outputPath: output,
      result: const TranscriptionResult(
        duration: 2,
        segments: <Segment>[Segment(text: '硬字幕验收', start: 0, end: 2, index: 0)],
      ),
      style: const SubtitleStyle(),
    );
    expect(File(output).existsSync(), isTrue);
    expect(await File(output).length(), greaterThan(1024));
  });
}
