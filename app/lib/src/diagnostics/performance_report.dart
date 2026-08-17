/// 文件转写性能诊断报告。
library;

import 'dart:convert';

/// 一次成功文件转写的耗时、配置和运行环境快照。
class PerformanceReport {
  const PerformanceReport({
    required this.generatedAt,
    required this.fileName,
    required this.platform,
    required this.language,
    required this.audioDuration,
    required this.sampleCount,
    required this.segmentCount,
    required this.elapsed,
    required this.decodeElapsed,
    required this.transcriptionElapsed,
    required this.modelPreparationElapsed,
    required this.modelBytes,
    required this.numThreads,
    required this.useItn,
    required this.partialInterval,
    required this.vadThreshold,
    required this.minSilenceDuration,
    required this.minSpeechDuration,
    required this.maxSpeechDuration,
  });

  final DateTime generatedAt;
  final String fileName;
  final String platform;
  final String language;
  final double audioDuration;
  final int sampleCount;
  final int segmentCount;

  /// 从开始解码到识别完成的耗时，不包含模型准备。
  final Duration elapsed;
  final Duration decodeElapsed;
  final Duration transcriptionElapsed;

  /// 本次任务触发模型准备时的耗时；复用已加载模型时为 null。
  final Duration? modelPreparationElapsed;

  /// 模型目录统计尚未完成或平台不可用时为 null，而不是误报 0 字节。
  final int? modelBytes;
  final int numThreads;
  final bool useItn;
  final double partialInterval;
  final double vadThreshold;
  final double minSilenceDuration;
  final double minSpeechDuration;
  final double maxSpeechDuration;

  double? get realTimeFactor {
    if (audioDuration <= 0) return null;
    return elapsed.inMicroseconds /
        Duration.microsecondsPerSecond /
        audioDuration;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'file_name': fileName,
    'platform': platform,
    'language': language,
    'audio_duration_seconds': audioDuration,
    'sample_count': sampleCount,
    'segment_count': segmentCount,
    'elapsed_ms': elapsed.inMilliseconds,
    'decode_elapsed_ms': decodeElapsed.inMilliseconds,
    'transcription_elapsed_ms': transcriptionElapsed.inMilliseconds,
    if (modelPreparationElapsed != null)
      'model_preparation_elapsed_ms': modelPreparationElapsed!.inMilliseconds,
    'real_time_factor': realTimeFactor,
    'model_bytes': modelBytes,
    'config': <String, Object>{
      'num_threads': numThreads,
      'use_itn': useItn,
      'partial_interval_seconds': partialInterval,
      'vad_threshold': vadThreshold,
      'min_silence_duration_seconds': minSilenceDuration,
      'min_speech_duration_seconds': minSpeechDuration,
      'max_speech_duration_seconds': maxSpeechDuration,
    },
  };

  String toJsonString() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  String toText() {
    final String preparation = modelPreparationElapsed == null
        ? '已复用已加载模型'
        : _formatMilliseconds(modelPreparationElapsed!);
    final String rtf = realTimeFactor == null
        ? '不可用'
        : realTimeFactor!.toStringAsFixed(3);
    return <String>[
      'VoiceSmallASR 性能诊断报告',
      '生成时间：${generatedAt.toLocal().toIso8601String()}',
      '文件：$fileName',
      '平台：$platform',
      '识别语言：$language',
      '音频时长：${audioDuration.toStringAsFixed(3)} 秒',
      '采样点：$sampleCount',
      '字幕段数：$segmentCount',
      '总耗时（解码+识别）：${_formatMilliseconds(elapsed)}',
      '解码耗时：${_formatMilliseconds(decodeElapsed)}',
      '识别耗时：${_formatMilliseconds(transcriptionElapsed)}',
      '模型准备：$preparation',
      'RTF：$rtf',
      '模型占用：${modelBytes == null ? '未统计' : _formatBytes(modelBytes!)}',
      '线程数：$numThreads',
      'ITN：${useItn ? '开启' : '关闭'}',
      '局部结果间隔：${partialInterval.toStringAsFixed(3)} 秒',
      'VAD：threshold=${vadThreshold.toStringAsFixed(3)}, '
          'minSilence=${minSilenceDuration.toStringAsFixed(3)} 秒, '
          'minSpeech=${minSpeechDuration.toStringAsFixed(3)} 秒, '
          'maxSpeech=${maxSpeechDuration.toStringAsFixed(3)} 秒',
    ].join('\n');
  }
}

String _formatMilliseconds(Duration duration) {
  return '${(duration.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(3)} 秒';
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '$bytes B';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
}
