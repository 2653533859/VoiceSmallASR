/// WAV 解码（纯 Dart）。对应 Python 端 `audio.py` 里 soundfile 直读 wav 的那条路径。
///
/// 之所以不用 `sherpa_onnx` 自带的 `readWave()`：它要求先 `initBindings()`，
/// 因此无法在 `flutter test` 里单测；而且它不做重采样，也不混声道。
/// 压缩格式（mp3/m4a/视频）不在这里处理，交给平台原生解码，见 `audio_decoder.dart`。
library;

import 'dart:typed_data';

import 'package:vsasr_app/src/asr/asr_config.dart';

/// WAV 格式不受支持或文件损坏。
class WavFormatException implements Exception {
  const WavFormatException(this.message);

  final String message;

  @override
  String toString() => 'WavFormatException: $message';
}

/// 一个 WAV 文件解码后的内容（已混成单声道，尚未重采样）。
class WavData {
  const WavData({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });

  /// 单声道 float32 采样，范围 [-1, 1]。
  final Float32List samples;

  /// 文件自身的采样率。
  final int sampleRate;

  /// 文件原始声道数（已被混成单声道，此处仅作记录）。
  final int channels;

  double get duration => samples.length / sampleRate;
}

const int _formatPcm = 1;
const int _formatFloat = 3;
const int _formatExtensible = 0xFFFE;

/// 解析 WAV 字节流。支持 8/16/24/32 位整型 PCM 与 32/64 位浮点，任意声道数。
///
/// 多声道按算术平均混成单声道，与 Python 端 `audio.load` 的 `data.mean(axis=1)` 一致。
WavData decodeWav(Uint8List bytes) {
  final ByteData view = ByteData.sublistView(bytes);
  if (bytes.length < 12) {
    throw const WavFormatException('文件太小，不是有效的 WAV');
  }
  if (_tag(bytes, 0) != 'RIFF' || _tag(bytes, 8) != 'WAVE') {
    throw const WavFormatException('缺少 RIFF/WAVE 头，不是 WAV 文件');
  }

  int format = -1;
  int channels = 0;
  int sampleRate = 0;
  int bitsPerSample = 0;
  Uint8List? data;

  // 逐个 chunk 走：除 fmt 与 data 之外还可能有 LIST/fact/cue 等，一律跳过。
  int offset = 12;
  while (offset + 8 <= bytes.length) {
    final String id = _tag(bytes, offset);
    final int size = view.getUint32(offset + 4, Endian.little);
    final int body = offset + 8;
    // 前进多少由声明的 size 决定，但 data chunk 例外，见下。
    int step = size;
    if (id == 'fmt ') {
      if (size < 16 || body + 16 > bytes.length) {
        throw const WavFormatException('fmt chunk 长度异常');
      }
      format = view.getUint16(body, Endian.little);
      channels = view.getUint16(body + 2, Endian.little);
      sampleRate = view.getUint32(body + 4, Endian.little);
      bitsPerSample = view.getUint16(body + 14, Endian.little);
      // WAVE_FORMAT_EXTENSIBLE 把真正的格式藏在 SubFormat GUID 的头两字节里。
      if (format == _formatExtensible && size >= 40 && body + 26 <= bytes.length) {
        format = view.getUint16(body + 24, Endian.little);
      }
    } else if (id == 'data') {
      // 有些编码器把 data 的 size 写成 0 或 0xFFFFFFFF（流式写入），此时取到文件末尾。
      final int available = bytes.length - body;
      final int length = (size == 0 || size > available) ? available : size;
      data = Uint8List.sublistView(bytes, body, body + length);
      // 必须按**裁剪后**的长度前进：size 写成 0 时按声明值前进等于原地不动，
      // 于是循环把 PCM 数据当成 chunk 头往下解析 —— 音频里任意四个字节恰好
      // 拼成 'data' 就会把 data 改指到后面的一小片，静默丢掉大半音频。
      step = length;
    }
    // chunk 按偶数字节对齐，奇数长度后面会补一个填充字节。
    offset = body + step + (step.isOdd ? 1 : 0);
  }

  if (format < 0 || channels <= 0 || sampleRate <= 0) {
    throw const WavFormatException('缺少 fmt chunk 或参数非法');
  }
  if (data == null) {
    throw const WavFormatException('缺少 data chunk');
  }
  if (format != _formatPcm && format != _formatFloat) {
    throw WavFormatException('不支持的 WAV 编码 $format（仅支持整型 PCM 与 IEEE float）');
  }

  final Float32List mono = _toMono(data, format, bitsPerSample, channels);
  return WavData(samples: mono, sampleRate: sampleRate, channels: channels);
}

String _tag(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes, offset, offset + 4);

/// 按位深读出各声道采样并混成单声道。
Float32List _toMono(Uint8List data, int format, int bits, int channels) {
  final int bytesPerSample = bits ~/ 8;
  if (bytesPerSample == 0) {
    throw WavFormatException('位深非法：$bits');
  }
  final int frames = data.length ~/ (bytesPerSample * channels);
  final Float32List out = Float32List(frames);
  final ByteData view = ByteData.sublistView(data);
  for (int frame = 0; frame < frames; frame++) {
    double sum = 0.0;
    for (int channel = 0; channel < channels; channel++) {
      final int at = (frame * channels + channel) * bytesPerSample;
      sum += _readSample(view, at, format, bits);
    }
    out[frame] = sum / channels;
  }
  return out;
}

/// 读单个采样并归一化到 [-1, 1]。
double _readSample(ByteData view, int at, int format, int bits) {
  if (format == _formatFloat) {
    return switch (bits) {
      32 => view.getFloat32(at, Endian.little),
      64 => view.getFloat64(at, Endian.little),
      _ => throw WavFormatException('浮点 WAV 不支持 $bits 位'),
    };
  }
  switch (bits) {
    case 8:
      // 8 位 WAV 按惯例是无符号，128 为静音。
      return (view.getUint8(at) - 128) / 128.0;
    case 16:
      return view.getInt16(at, Endian.little) / 32768.0;
    case 24:
      final int raw = view.getUint8(at) |
          (view.getUint8(at + 1) << 8) |
          (view.getUint8(at + 2) << 16);
      // 手工做符号扩展：24 位没有现成的 getInt24。
      final int signed = (raw & 0x800000) != 0 ? raw - 0x1000000 : raw;
      return signed / 8388608.0;
    case 32:
      return view.getInt32(at, Endian.little) / 2147483648.0;
    default:
      throw WavFormatException('整型 WAV 不支持 $bits 位');
  }
}

/// 线性插值重采样。
///
/// 质量不如 ffmpeg 的多相滤波器（Python 端用的就是 ffmpeg），但只在
/// 「非 16 kHz 的 wav」这条次要路径上用；压缩格式走原生解码，重采样由
/// AVAudioConverter / MediaCodec 那一侧负责。采样率相同时原样返回，
/// 因此 16 kHz 素材（含模型自带的 test_wavs）不经过任何插值，
/// 与 Python 端逐字对照的前提得以保留。
Float32List resampleLinear(Float32List samples, int from, int to) {
  if (from <= 0 || to <= 0) {
    throw ArgumentError('采样率必须为正：from=$from to=$to');
  }
  if (from == to || samples.isEmpty) return samples;
  final int length = (samples.length * to / from).floor();
  if (length <= 0) return Float32List(0);
  final Float32List out = Float32List(length);
  final double step = from / to;
  for (int i = 0; i < length; i++) {
    final double position = i * step;
    final int left = position.floor();
    final int right = left + 1 < samples.length ? left + 1 : samples.length - 1;
    final double fraction = position - left;
    out[i] = samples[left] * (1 - fraction) + samples[right] * fraction;
  }
  return out;
}

/// 解码 WAV 并归一化成模型要求的输入：16 kHz、float32、单声道。
Float32List decodeWavToModelInput(Uint8List bytes) {
  final WavData wav = decodeWav(bytes);
  return resampleLinear(wav.samples, wav.sampleRate, kSampleRate);
}
