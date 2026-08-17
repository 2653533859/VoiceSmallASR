/// 无签名 macOS/桌面 FFmpeg 硬字幕验收。
///
/// 该脚本不启动 macOS Runner，因此不需要开发证书；只有显式提供输入视频时才运行：
///
/// ```bash
/// VSASR_FFMPEG_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg \
/// VSASR_HARD_SUBTITLE_TEST_VIDEO=/path/to/input.mp4 \
/// flutter test tool/hard_subtitle_ffmpeg_acceptance_test.dart
/// ```
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_style.dart';
import 'package:vsasr_app/src/video/hard_subtitle_encoder.dart';

const String _definedInput = String.fromEnvironment(
  'VSASR_HARD_SUBTITLE_TEST_VIDEO',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FFmpeg 硬字幕输出可被 FFmpeg 重新解码', () async {
    final String? inputPath = _setting(
      _definedInput,
      'VSASR_HARD_SUBTITLE_TEST_VIDEO',
    );
    if (inputPath == null) {
      markTestSkipped('未提供 VSASR_HARD_SUBTITLE_TEST_VIDEO');
      return;
    }
    expect(File(inputPath).existsSync(), isTrue, reason: '输入视频不存在：$inputPath');

    final Directory outputDirectory = await Directory.systemTemp.createTemp(
      'vsasr-hard-subtitle-vm-acceptance-',
    );
    final String outputPath = p.join(outputDirectory.path, 'output.mp4');
    addTearDown(() async {
      if (outputDirectory.existsSync()) {
        await outputDirectory.delete(recursive: true);
      }
    });

    await FfmpegHardSubtitleEncoder().encode(
      inputPath: inputPath,
      outputPath: outputPath,
      result: const TranscriptionResult(
        duration: 2,
        segments: <Segment>[
          Segment(
            text: '硬字幕原文',
            translation: 'Hard subtitle translation',
            speaker: 'acceptance',
            start: 0,
            end: 2,
            index: 0,
          ),
        ],
      ),
      style: const SubtitleStyle(),
    );

    final File output = File(outputPath);
    expect(output.existsSync(), isTrue);
    expect(await output.length(), greaterThan(1024));

    final ProcessResult probe = await Process.run(_ffmpegExecutable(), <String>[
      '-hide_banner',
      '-nostdin',
      '-loglevel',
      'error',
      '-i',
      outputPath,
      '-f',
      'null',
      '-',
    ]);
    expect(probe.exitCode, 0, reason: '硬字幕输出无法重新解码：${probe.stderr}');
  });
}

String? _setting(String defined, String name) {
  final String value = defined.trim();
  if (value.isNotEmpty) return value;
  final String? environment = Platform.environment[name]?.trim();
  return environment == null || environment.isEmpty ? null : environment;
}

String _ffmpegExecutable() {
  final String? configured = Platform.environment['VSASR_FFMPEG_PATH']?.trim();
  return configured == null || configured.isEmpty ? 'ffmpeg' : configured;
}
