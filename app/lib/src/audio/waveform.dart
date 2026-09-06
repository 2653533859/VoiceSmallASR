/// 按可见时间窗口提取峰值波形，不保留整段 PCM。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vsasr_app/src/audio/audio_decoder.dart';

class WaveformData {
  const WaveformData(this.peaks, this.decodedSeconds);
  final Float32List peaks;
  final double decodedSeconds;
}

Future<WaveformData> loadWaveform({
  required String path,
  required double start,
  required double duration,
  int bins = 600,
  ResumableChunkedAudioDecoder decoder = const PlatformAudioDecoder(),
  bool Function()? isCancelled,
}) async {
  if (!start.isFinite ||
      start < 0 ||
      !duration.isFinite ||
      duration <= 0 ||
      duration > 120 ||
      bins < 1 ||
      bins > 2400) {
    throw ArgumentError('波形窗口必须为 0–120 秒，且起点有效');
  }
  final peaks = Float32List(bins);
  final total = (duration * 16000).ceil();
  final startMs = (start * 1000).floor();
  int skip = (start * 16000).round() - startMs * 16;
  int processed = 0;
  await for (final chunk in decoder.decodeFileChunksFrom(
    path,
    startAt: Duration(milliseconds: startMs),
    chunkDuration: const Duration(seconds: 2),
  )) {
    if (isCancelled?.call() ?? false) break;
    for (final value in chunk.samples) {
      if (skip > 0) {
        skip--;
        continue;
      }
      if (processed >= total) break;
      final bin = math.min(bins - 1, processed * bins ~/ total);
      if (value.isFinite) {
        peaks[bin] = math.max(peaks[bin], value.abs().clamp(0, 1));
      }
      processed++;
    }
    if (processed >= total) break;
  }
  return WaveformData(peaks, processed / 16000);
}
