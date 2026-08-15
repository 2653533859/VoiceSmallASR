/// 测试用 WAV 字节流构造器。
///
/// 单测不该依赖仓库里的二进制素材（`.gitignore` 把音频全排除了），
/// 因此各种位深/声道/chunk 排布都在这里现场拼出来。
library;

import 'dart:typed_data';

const int wavFormatPcm = 1;
const int wavFormatFloat = 3;
const int wavFormatExtensible = 0xFFFE;

/// 拼一个 WAV 文件。
///
/// [frames] 的每一项是一帧里各声道的采样值（范围 [-1, 1]），
/// 因此 `[[0.5], [-0.5]]` 是单声道两帧，`[[1.0, -1.0]]` 是立体声一帧。
Uint8List buildWav({
  required List<List<double>> frames,
  int sampleRate = 16000,
  int bitsPerSample = 16,
  int format = wavFormatPcm,
  int? subFormat,
  List<int> extraChunks = const <int>[],
  int? dataSizeOverride,
  bool includeFmt = true,
  bool includeData = true,
  String riffTag = 'RIFF',
  String waveTag = 'WAVE',
}) {
  final int channels = frames.isEmpty ? 1 : frames.first.length;
  final int bytesPerSample = bitsPerSample ~/ 8;
  final BytesBuilder payload = BytesBuilder();
  for (final List<double> frame in frames) {
    for (final double value in frame) {
      payload.add(_encodeSample(value, format, bitsPerSample));
    }
  }
  final Uint8List data = payload.toBytes();

  final BytesBuilder body = BytesBuilder()..add(extraChunks);
  if (includeFmt) {
    final bool extensible = format == wavFormatExtensible;
    final ByteData fmt = ByteData(extensible ? 40 : 16);
    fmt.setUint16(0, format, Endian.little);
    fmt.setUint16(2, channels, Endian.little);
    fmt.setUint32(4, sampleRate, Endian.little);
    fmt.setUint32(8, sampleRate * channels * bytesPerSample, Endian.little);
    fmt.setUint16(12, channels * bytesPerSample, Endian.little);
    fmt.setUint16(14, bitsPerSample, Endian.little);
    if (extensible) {
      fmt.setUint16(16, 22, Endian.little); // cbSize
      fmt.setUint16(18, bitsPerSample, Endian.little);
      fmt.setUint16(24, subFormat ?? wavFormatPcm, Endian.little);
    }
    body.add(_chunk('fmt ', fmt.buffer.asUint8List()));
  }
  if (includeData) {
    body.add(_chunk('data', data, sizeOverride: dataSizeOverride));
  }
  final Uint8List bodyBytes = body.toBytes();

  final BytesBuilder out = BytesBuilder()
    ..add(_ascii(riffTag))
    ..add(_uint32(4 + bodyBytes.length))
    ..add(_ascii(waveTag))
    ..add(bodyBytes);
  return out.toBytes();
}

/// 一个任意内容的 chunk，用于验证解析器会跳过不认识的 chunk。
Uint8List filler(String id, int length) =>
    _chunk(id, Uint8List.fromList(List<int>.filled(length, 0x7A)));

Uint8List _chunk(String id, Uint8List body, {int? sizeOverride}) {
  final BytesBuilder out = BytesBuilder()
    ..add(_ascii(id))
    ..add(_uint32(sizeOverride ?? body.length))
    ..add(body);
  if (body.length.isOdd) out.addByte(0); // chunk 按偶数字节对齐
  return out.toBytes();
}

Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);

Uint8List _uint32(int value) {
  final ByteData out = ByteData(4)..setUint32(0, value, Endian.little);
  return out.buffer.asUint8List();
}

Uint8List _encodeSample(double value, int format, int bits) {
  if (format == wavFormatFloat) {
    final ByteData out = ByteData(bits ~/ 8);
    if (bits == 64) {
      out.setFloat64(0, value, Endian.little);
    } else {
      out.setFloat32(0, value, Endian.little);
    }
    return out.buffer.asUint8List();
  }
  switch (bits) {
    case 8:
      return Uint8List.fromList(<int>[(value * 128 + 128).round().clamp(0, 255)]);
    case 16:
      final ByteData out = ByteData(2)
        ..setInt16(0, (value * 32768).round().clamp(-32768, 32767), Endian.little);
      return out.buffer.asUint8List();
    case 24:
      final int raw = (value * 8388608).round().clamp(-8388608, 8388607);
      final int unsigned = raw < 0 ? raw + 0x1000000 : raw;
      return Uint8List.fromList(<int>[
        unsigned & 0xFF,
        (unsigned >> 8) & 0xFF,
        (unsigned >> 16) & 0xFF,
      ]);
    case 32:
      final ByteData out = ByteData(4)
        ..setInt32(0, (value * 2147483648).round().clamp(-2147483648, 2147483647), Endian.little);
      return out.buffer.asUint8List();
    default:
      throw ArgumentError('测试构造器不支持 $bits 位');
  }
}
