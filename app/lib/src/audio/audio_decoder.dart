/// 统一音频解码入口：文件 → 16 kHz float32 单声道。
///
/// 与 Python 端 `audio.py` 的分工相同 —— wav 直读，其余格式交给外部解码器 ——
/// 但 Dart 侧没有 ffmpeg 可调（`ffmpeg_kit_flutter` 已弃养且不支持 Windows），
/// 因此压缩格式与视频走**平台原生解码**，三端各实现一份：
///
/// * Android：`MediaExtractor` + `MediaCodec`（混声道与重采样自己做）
/// * macOS：`AVAssetReader` + `AVAssetReaderAudioMixOutput`
/// * Windows：Media Foundation `IMFSourceReader`
///
/// 原生侧的契约只有一条：给绝对路径，回 16 kHz、单声道、float32 的采样，
/// 重采样与混声道都在原生侧完成，Dart 层不感知平台差异。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/audio/wav.dart';

/// 原生解码通道。方法 `decodeToPcm16k`，参数 `{'path': String}`，
/// 返回 [Float32List]（16 kHz 单声道）。
const MethodChannel kAudioDecoderChannel = MethodChannel('vsasr/audio_decoder');

/// 纯 Dart 直读的格式。
const List<String> kWavExtensions = <String>['wav', 'wave'];

/// 需要平台原生解码的格式（音频 + 视频容器，视频只取音轨）。
const List<String> kNativeAudioExtensions = <String>[
  'mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wma', 'aiff', 'caf',
  'mp4', 'mov', 'mkv', 'avi', 'webm', 'ts', 'flv',
];

/// 文件选择器可用的扩展名白名单。
List<String> get kSupportedAudioExtensions =>
    <String>[...kWavExtensions, ...kNativeAudioExtensions];

/// 解码失败。[message] 已是可直接展示给用户的中文说明。
class AudioDecodeException implements Exception {
  const AudioDecodeException(this.message, {this.path});

  final String message;
  final String? path;

  @override
  String toString() =>
      path == null ? 'AudioDecodeException: $message' : 'AudioDecodeException: $message（$path）';
}

/// 音频解码器。
abstract interface class AudioDecoder {
  /// 把 [path] 解成 16 kHz float32 单声道采样。
  Future<Float32List> decodeFile(String path);
}

/// 默认解码器：wav 走纯 Dart，其余交给平台原生实现。
class PlatformAudioDecoder implements AudioDecoder {
  const PlatformAudioDecoder({this.channel = kAudioDecoderChannel});

  final MethodChannel channel;

  @override
  Future<Float32List> decodeFile(String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      throw AudioDecodeException('音频文件不存在', path: path);
    }
    final String extension = p.extension(path).replaceFirst('.', '').toLowerCase();

    if (kWavExtensions.contains(extension)) {
      final Uint8List bytes = await file.readAsBytes();
      try {
        return decodeWavToModelInput(bytes);
      } on WavFormatException {
        // 扩展名是 wav 但内容是压缩编码（如 ADPCM），交给原生再试一次。
        return _decodeNative(path, extension);
      }
    }
    return _decodeNative(path, extension);
  }

  Future<Float32List> _decodeNative(String path, String extension) async {
    try {
      final Object? result = await channel.invokeMethod<Object?>(
        'decodeToPcm16k',
        <String, Object?>{'path': path},
      );
      return _asFloat32(result, path);
    } on MissingPluginException {
      // 该平台还没接原生解码（见 DEVELOPMENT_PLAN.md 的 M1）。
      throw AudioDecodeException(
        '当前平台尚未实现 .$extension 的解码，暂时只支持 wav。'
        '可先用 ffmpeg 转成 16 kHz 单声道 wav 再导入',
        path: path,
      );
    } on PlatformException catch (error) {
      throw AudioDecodeException('解码失败：${error.message ?? error.code}', path: path);
    }
  }

  /// 原生侧正常返回 [Float32List]；顺带兼容按字节回传的实现，
  /// 免得某一端为了这点差异单独改协议。
  static Float32List _asFloat32(Object? result, String path) {
    if (result is Float32List) return result;
    if (result is Uint8List) {
      if (result.lengthInBytes % 4 != 0) {
        throw AudioDecodeException('原生返回的字节数不是 4 的倍数，无法当作 float32', path: path);
      }
      // 不能直接 Float32List.view：平台通道给的 buffer 未必按 4 字节对齐。
      final ByteData view = ByteData.sublistView(result);
      final Float32List out = Float32List(result.lengthInBytes ~/ 4);
      for (int i = 0; i < out.length; i++) {
        out[i] = view.getFloat32(i * 4, Endian.little);
      }
      return out;
    }
    if (result is List<double>) return Float32List.fromList(result);
    throw AudioDecodeException('原生解码没有返回采样数据（${result.runtimeType}）', path: path);
  }
}
