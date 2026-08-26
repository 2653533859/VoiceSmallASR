/// 视频流式转写的可诊断指标，不包含字幕正文。
library;

class VideoTranscriptionStalledException implements Exception {
  const VideoTranscriptionStalledException({
    required this.path,
    required this.phase,
    required this.timeout,
  });

  final String path;
  final String phase;
  final Duration timeout;

  String get message => '视频转写在$phase阶段超过 ${timeout.inSeconds} 秒没有进展，可重试';

  @override
  String toString() => 'VideoTranscriptionStalledException: $message（$path）';
}

class VideoTranscriptionReport {
  const VideoTranscriptionReport({
    required this.path,
    required this.startedAt,
    required this.queueWait,
    required this.elapsed,
    required this.decodeElapsed,
    required this.transcriptionElapsed,
    required this.decodedSamples,
    required this.processedSamples,
    required this.chunkCount,
    required this.peakRssBytes,
    required this.lastProgressAt,
    required this.completed,
  });

  final String path;
  final DateTime startedAt;
  final Duration queueWait;
  final Duration elapsed;
  final Duration decodeElapsed;
  final Duration transcriptionElapsed;
  final int decodedSamples;
  final int processedSamples;
  final int chunkCount;
  final int peakRssBytes;
  final DateTime lastProgressAt;
  final bool completed;

  double get decodedDurationSeconds => decodedSamples / 16000;

  double get processedDurationSeconds => processedSamples / 16000;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'started_at': startedAt.toUtc().toIso8601String(),
    'queue_wait_ms': queueWait.inMilliseconds,
    'elapsed_ms': elapsed.inMilliseconds,
    'decode_elapsed_ms': decodeElapsed.inMilliseconds,
    'transcription_elapsed_ms': transcriptionElapsed.inMilliseconds,
    'decoded_samples': decodedSamples,
    'processed_samples': processedSamples,
    'chunk_count': chunkCount,
    'peak_rss_bytes': peakRssBytes,
    'last_progress_at': lastProgressAt.toUtc().toIso8601String(),
    'completed': completed,
  };
}
