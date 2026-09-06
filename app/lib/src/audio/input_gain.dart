/// 识别输入增益：在 VAD 之前应用一次，不影响播放器或原媒体。
library;

import 'dart:math' as math;
import 'dart:typed_data';

Float32List applyInputGain(Float32List samples, double gainDb) {
  if (!gainDb.isFinite || gainDb < 0 || gainDb > 12) {
    throw ArgumentError.value(gainDb, 'gainDb', '必须在 0 到 12 dB 之间');
  }
  if (gainDb == 0) return samples;
  final double scale = math.pow(10, gainDb / 20).toDouble();
  final Float32List output = Float32List(samples.length);
  for (int i = 0; i < samples.length; i++) {
    final double value = samples[i] * scale;
    // 增益有上限，输出限幅；不按静音的峰值自动归一化或放大到满幅。
    output[i] = value.isFinite ? value.clamp(-1.0, 1.0) : 0;
  }
  return output;
}
