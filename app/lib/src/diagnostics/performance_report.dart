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

/// 一次批量识别的聚合性能报告。
class BatchPerformanceReport {
  BatchPerformanceReport({
    required this.generatedAt,
    required this.totalCount,
    required this.completedCount,
    required this.failedCount,
    required this.cancelledCount,
    required this.modelPreparationElapsed,
    required Iterable<PerformanceReport> reports,
  }) : reports = List<PerformanceReport>.unmodifiable(reports);

  final DateTime generatedAt;
  final int totalCount;
  final int completedCount;
  final int failedCount;
  final int cancelledCount;
  final Duration? modelPreparationElapsed;
  final List<PerformanceReport> reports;

  double get audioDuration => reports.fold<double>(
    0,
    (double total, PerformanceReport report) => total + report.audioDuration,
  );

  Duration get decodeElapsed => reports.fold<Duration>(
    Duration.zero,
    (Duration total, PerformanceReport report) => total + report.decodeElapsed,
  );

  Duration get transcriptionElapsed => reports.fold<Duration>(
    Duration.zero,
    (Duration total, PerformanceReport report) =>
        total + report.transcriptionElapsed,
  );

  /// 已记录的模型准备、解码和识别耗时之和，不代表整个队列的墙钟耗时。
  Duration get elapsed => reports.fold<Duration>(
    modelPreparationElapsed ?? Duration.zero,
    (Duration total, PerformanceReport report) => total + report.elapsed,
  );

  double? get realTimeFactor {
    if (audioDuration <= 0) return null;
    return elapsed.inMicroseconds /
        Duration.microsecondsPerSecond /
        audioDuration;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'total_count': totalCount,
    'completed_count': completedCount,
    'failed_count': failedCount,
    'cancelled_count': cancelledCount,
    'audio_duration_seconds': audioDuration,
    'elapsed_ms': elapsed.inMilliseconds,
    'decode_elapsed_ms': decodeElapsed.inMilliseconds,
    'transcription_elapsed_ms': transcriptionElapsed.inMilliseconds,
    if (modelPreparationElapsed != null)
      'model_preparation_elapsed_ms': modelPreparationElapsed!.inMilliseconds,
    'real_time_factor': realTimeFactor,
    'files': reports
        .map((PerformanceReport report) => report.toJson())
        .toList(),
  };

  String toJsonString() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  String toText() {
    final String rtf = realTimeFactor == null
        ? '不可用'
        : realTimeFactor!.toStringAsFixed(3);
    return <String>[
      'VoiceSmallASR 批量性能汇总',
      '生成时间：${generatedAt.toLocal().toIso8601String()}',
      '文件数：$totalCount（完成 $completedCount，失败 $failedCount，取消 $cancelledCount）',
      '已统计音频：${audioDuration.toStringAsFixed(3)} 秒',
      '已统计耗时（模型准备+解码+识别）：${_formatMilliseconds(elapsed)}',
      '解码耗时：${_formatMilliseconds(decodeElapsed)}',
      '识别耗时：${_formatMilliseconds(transcriptionElapsed)}',
      'RTF：$rtf',
      '单文件报告：${reports.length} 份',
    ].join('\n');
  }
}

/// 一次实时字幕会话的聚合性能报告。
class LivePerformanceReport {
  const LivePerformanceReport({
    required this.generatedAt,
    required this.platform,
    required this.language,
    required this.audioDuration,
    required this.sampleCount,
    required this.segmentCount,
    required this.elapsed,
  });

  final DateTime generatedAt;
  final String platform;
  final String language;
  final double audioDuration;
  final int sampleCount;
  final int segmentCount;

  /// 从实时会话开始到收尾完成的墙钟耗时。
  final Duration elapsed;

  double? get realTimeFactor {
    if (audioDuration <= 0) return null;
    return elapsed.inMicroseconds /
        Duration.microsecondsPerSecond /
        audioDuration;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'platform': platform,
    'language': language,
    'audio_duration_seconds': audioDuration,
    'sample_count': sampleCount,
    'segment_count': segmentCount,
    'elapsed_ms': elapsed.inMilliseconds,
    'real_time_factor': realTimeFactor,
  };

  String toJsonString() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  String toText() {
    final String rtf = realTimeFactor == null
        ? '不可用'
        : realTimeFactor!.toStringAsFixed(3);
    return <String>[
      'VoiceSmallASR 实时性能报告',
      '生成时间：${generatedAt.toLocal().toIso8601String()}',
      '平台：$platform',
      '识别语言：$language',
      '音频时长：${audioDuration.toStringAsFixed(3)} 秒',
      '采样点：$sampleCount',
      '字幕段数：$segmentCount',
      '会话耗时：${_formatMilliseconds(elapsed)}',
      'RTF：$rtf',
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
