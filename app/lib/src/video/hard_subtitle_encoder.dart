/// 使用系统 FFmpeg 将字幕烧录进视频文件。
///
/// 项目不把 FFmpeg 二进制打进安装包：桌面用户需要自行安装 `ffmpeg`，
/// 或通过 `VSASR_FFMPEG_PATH` 指定可执行文件路径。Android 不提供进程级
/// FFmpeg，因此由 UI 层在启动编码前给出明确提示。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_style.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

typedef HardSubtitleProgress = void Function(double? progress);

class HardSubtitleEncodeException implements Exception {
  const HardSubtitleEncodeException(this.message);

  final String message;

  @override
  String toString() => 'HardSubtitleEncodeException: $message';
}

abstract interface class HardSubtitleEncoder {
  Future<void> encode({
    required String inputPath,
    required String outputPath,
    required TranscriptionResult result,
    required SubtitleStyle style,
    HardSubtitleProgress? onProgress,
  });
}

/// 基于本机 FFmpeg 的桌面硬字幕编码器。
class FfmpegHardSubtitleEncoder implements HardSubtitleEncoder {
  FfmpegHardSubtitleEncoder({String? executable})
    : executable = executable ?? _defaultFfmpegExecutable();

  final String executable;

  @override
  Future<void> encode({
    required String inputPath,
    required String outputPath,
    required TranscriptionResult result,
    required SubtitleStyle style,
    HardSubtitleProgress? onProgress,
  }) async {
    _validatePaths(inputPath, outputPath);
    ensureValidSubtitleTimeline(result.segments, duration: result.duration);
    final Directory subtitleDirectory = await Directory.systemTemp.createTemp(
      'vsasr-hard-subtitles-',
    );
    final File assFile = File(p.join(subtitleDirectory.path, 'subtitles.ass'));
    try {
      await assFile.writeAsString(buildAssSubtitle(result, style));
      onProgress?.call(0.0);
      final List<String> arguments = <String>[
        '-hide_banner',
        '-nostdin',
        '-loglevel',
        'error',
        '-y',
        '-progress',
        'pipe:1',
        '-i',
        inputPath,
        '-map',
        '0:v:0',
        '-map',
        '0:a?',
        '-vf',
        "ass=filename='${_escapeFilterPath(assFile.path)}'",
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '18',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-b:a',
        '192k',
        '-movflags',
        '+faststart',
        outputPath,
      ];
      final Process process;
      try {
        process = await Process.start(executable, arguments, runInShell: false);
      } on ProcessException catch (error) {
        throw HardSubtitleEncodeException(
          '找不到 FFmpeg：${error.message}。请安装 ffmpeg，或设置 VSASR_FFMPEG_PATH',
        );
      }

      final Future<String> errorOutput = process.stderr
          .transform(utf8.decoder)
          .join();
      await for (final String line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        final String value = line.trim();
        if (!value.startsWith('out_time_us=')) continue;
        final int? microseconds = int.tryParse(
          value.substring('out_time_us='.length),
        );
        if (microseconds == null || result.duration <= 0) continue;
        final double progress = (microseconds / 1000000) / result.duration;
        onProgress?.call(progress.clamp(0.0, 1.0));
      }
      final int exitCode = await process.exitCode;
      final String error = (await errorOutput).trim();
      if (exitCode != 0) {
        throw HardSubtitleEncodeException(
          'FFmpeg 编码失败（退出码 $exitCode）：${_formatFfmpegError(error)}',
        );
      }
      onProgress?.call(1.0);
    } finally {
      if (subtitleDirectory.existsSync()) {
        await subtitleDirectory.delete(recursive: true);
      }
    }
  }
}

/// 生成 FFmpeg ASS 滤镜使用的字幕文件。
String buildAssSubtitle(TranscriptionResult result, SubtitleStyle style) {
  final StringBuffer output = StringBuffer()
    ..writeln('[Script Info]')
    ..writeln('ScriptType: v4.00+')
    ..writeln('PlayResX: 1920')
    ..writeln('PlayResY: 1080')
    ..writeln('ScaledBorderAndShadow: yes')
    ..writeln()
    ..writeln('[V4+ Styles]')
    ..writeln(
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
      'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
      'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
      'Alignment, MarginL, MarginR, MarginV, Encoding',
    )
    ..writeln(
      'Style: Default,Arial,${style.fontSize},${_assColor(style.textColor)},'
      '${_assColor(style.textColor)},${_assColor(0xFF000000)},'
      '${_assColor(style.backgroundColor)},0,0,0,0,100,100,0,0,3,0,0,'
      '${_assAlignment(style.position)},40,40,20,1',
    )
    ..writeln()
    ..writeln('[Events]')
    ..writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
      'Effect, Text',
    );

  for (final Segment segment in result.segments) {
    final List<String> lines = <String>[
      if ((segment.speaker ?? '').trim().isNotEmpty)
        '【${segment.speaker!.trim()}】',
      if (segment.text.trim().isNotEmpty) segment.text.trim(),
      if ((segment.translation ?? '').trim().isNotEmpty)
        segment.translation!.trim(),
    ];
    if (lines.isEmpty) continue;
    output.writeln(
      'Dialogue: 0,${_assTime(segment.start)},${_assTime(segment.end)},'
      'Default,,0,0,0,,${_assText(lines.join('\n'))}',
    );
  }
  return output.toString();
}

String _defaultFfmpegExecutable() =>
    Platform.environment['VSASR_FFMPEG_PATH']?.trim().isNotEmpty == true
    ? Platform.environment['VSASR_FFMPEG_PATH']!.trim()
    : 'ffmpeg';

void _validatePaths(String inputPath, String outputPath) {
  final String input = p.normalize(p.absolute(inputPath));
  final String output = p.normalize(p.absolute(outputPath));
  if (inputPath.trim().isEmpty || outputPath.trim().isEmpty) {
    throw const HardSubtitleEncodeException('输入和输出视频路径不能为空');
  }
  if (!File(input).existsSync()) {
    throw HardSubtitleEncodeException('输入视频不存在：$inputPath');
  }
  if (input == output) {
    throw const HardSubtitleEncodeException('输出视频不能覆盖输入视频，请选择新文件名');
  }
  if (p.extension(output).toLowerCase() != '.mp4') {
    throw const HardSubtitleEncodeException('硬字幕输出目前只支持 .mp4 文件');
  }
}

String _assTime(double seconds) {
  final int centiseconds = (seconds.clamp(0.0, double.infinity) * 100).round();
  final int hours = centiseconds ~/ 360000;
  final int minutes = (centiseconds % 360000) ~/ 6000;
  final int remainingSeconds = (centiseconds % 6000) ~/ 100;
  final int fraction = centiseconds % 100;
  return '$hours:${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}.${fraction.toString().padLeft(2, '0')}';
}

String _assText(String value) => value
    .replaceAll('\\', r'\\')
    .replaceAll('{', r'\{')
    .replaceAll('}', r'\}')
    .replaceAll('\r', '')
    .replaceAll('\n', r'\N');

String _escapeFilterPath(String path) =>
    path.replaceAll('\\', '/').replaceAll(':', r'\:').replaceAll("'", r"\'");

String _assColor(int argb) {
  final int alpha = 255 - ((argb >> 24) & 0xFF);
  final int red = (argb >> 16) & 0xFF;
  final int green = (argb >> 8) & 0xFF;
  final int blue = argb & 0xFF;
  return '&H${alpha.toRadixString(16).padLeft(2, '0')}'
      '${blue.toRadixString(16).padLeft(2, '0')}'
      '${green.toRadixString(16).padLeft(2, '0')}'
      '${red.toRadixString(16).padLeft(2, '0')}';
}

int _assAlignment(SubtitlePosition position) {
  switch (position) {
    case SubtitlePosition.top:
      return 8;
    case SubtitlePosition.center:
      return 5;
    case SubtitlePosition.bottom:
      return 2;
  }
}

String _truncate(String value) {
  const int limit = 800;
  if (value.length <= limit) return value;
  return '${value.substring(value.length - limit)}…';
}

String _formatFfmpegError(String error) {
  if (error.contains("No such filter: 'ass'") ||
      error.contains('No such filter: ass')) {
    return '当前 FFmpeg 未包含 libass/ass 字幕滤镜，请安装带 libass 的完整构建（如 ffmpeg-full）';
  }
  final String value = _truncate(error);
  return value.isEmpty ? '未返回错误详情' : value;
}
