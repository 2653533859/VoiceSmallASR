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

/// 播放器与文件转写共用的视频容器白名单。
const List<String> kVideoExtensions = <String>[
  'mp4',
  'mov',
  'mkv',
  'avi',
  'webm',
  'ts',
  'flv',
];

/// 需要平台原生解码的格式（音频 + 视频容器，视频只取音轨）。
const List<String> kNativeAudioExtensions = <String>[
  'mp3',
  'm4a',
  'aac',
  'flac',
  'ogg',
  'opus',
  'wma',
  'aiff',
  'caf',
  ...kVideoExtensions,
];

/// 文件选择器可用的扩展名白名单。
List<String> get kSupportedAudioExtensions => <String>[
  ...kWavExtensions,
  ...kNativeAudioExtensions,
];

/// 解码失败。[message] 已是可直接展示给用户的中文说明。
class AudioDecodeException implements Exception {
  const AudioDecodeException(this.message, {this.path});

  final String message;
  final String? path;

  @override
  String toString() => path == null
      ? 'AudioDecodeException: $message'
      : 'AudioDecodeException: $message（$path）';
}

/// 音频解码器。
abstract interface class AudioDecoder {
  /// 把 [path] 解成 16 kHz float32 单声道采样。
  Future<Float32List> decodeFile(String path);
}

/// 可按时间片解码的音频解码器，供长视频边解码边识别。
abstract interface class ChunkedAudioDecoder {
  Stream<DecodedAudioChunk> decodeFileChunks(
    String path, {
    Duration chunkDuration = const Duration(seconds: 10),
  });
}

/// 支持从已完成的音频位置继续分块解码的解码器。
///
/// 单独定义该接口是为了不破坏测试替身和第三方解码器；不支持续接时，
/// 调用方会安全地从文件开头重新解码。
abstract interface class ResumableChunkedAudioDecoder {
  Stream<DecodedAudioChunk> decodeFileChunksFrom(
    String path, {
    required Duration startAt,
    Duration chunkDuration = const Duration(seconds: 10),
  });
}

class DecodedAudioChunk {
  const DecodedAudioChunk(this.samples, {required this.isLast});

  final Float32List samples;
  final bool isLast;
}

/// 默认解码器：wav 走纯 Dart，其余交给平台原生实现。
class PlatformAudioDecoder
    implements AudioDecoder, ChunkedAudioDecoder, ResumableChunkedAudioDecoder {
  const PlatformAudioDecoder({this.channel = kAudioDecoderChannel});

  final MethodChannel channel;

  @override
  Future<Float32List> decodeFile(String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      throw AudioDecodeException('音频文件不存在', path: path);
    }
    final String extension = p
        .extension(path)
        .replaceFirst('.', '')
        .toLowerCase();

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

  @override
  Stream<DecodedAudioChunk> decodeFileChunks(
    String path, {
    Duration chunkDuration = const Duration(seconds: 10),
  }) => decodeFileChunksFrom(
    path,
    startAt: Duration.zero,
    chunkDuration: chunkDuration,
  );

  @override
  Stream<DecodedAudioChunk> decodeFileChunksFrom(
    String path, {
    required Duration startAt,
    Duration chunkDuration = const Duration(seconds: 10),
  }) async* {
    if (chunkDuration <= Duration.zero) {
      throw ArgumentError.value(chunkDuration, 'chunkDuration', '必须大于 0');
    }
    if (startAt < Duration.zero) {
      throw ArgumentError.value(startAt, 'startAt', '不能小于 0');
    }
    final File file = File(path);
    if (!file.existsSync()) {
      throw AudioDecodeException('音频文件不存在', path: path);
    }
    final String extension = p
        .extension(path)
        .replaceFirst('.', '')
        .toLowerCase();
    if (kWavExtensions.contains(extension)) {
      try {
        await for (final WavAudioChunk chunk in decodeWavFileChunks(
          file,
          startSample:
              startAt.inMicroseconds * 16000 ~/ Duration.microsecondsPerSecond,
          chunkSamples:
              (chunkDuration.inMicroseconds *
                      16000 ~/
                      Duration.microsecondsPerSecond)
                  .clamp(1, 0x7fffffffffffffff),
        )) {
          yield DecodedAudioChunk(chunk.samples, isLast: chunk.isLast);
        }
        return;
      } on WavFormatException {
        // 压缩 WAV 与其他原生格式一样使用分块会话，避免全量回退。
      }
    }

    if (Platform.isMacOS || Platform.isAndroid || Platform.isWindows) {
      yield* _decodeNativeStream(path, chunkDuration, startAt);
      return;
    }

    yield* _decodeLegacyNativeChunks(path, chunkDuration, startAt);
  }

  Stream<DecodedAudioChunk> _decodeNativeStream(
    String path,
    Duration chunkDuration,
    Duration startAt,
  ) async* {
    String? sessionId;
    try {
      sessionId = await channel.invokeMethod<String>(
        'openPcm16kStream',
        <String, Object?>{'path': path, 'startMs': startAt.inMilliseconds},
      );
      if (sessionId == null || sessionId.isEmpty) {
        throw AudioDecodeException('原生持续解码会话启动失败', path: path);
      }
      while (true) {
        final Object? response = await channel.invokeMethod<Object?>(
          'readPcm16kStream',
          <String, Object?>{
            'sessionId': sessionId,
            'maxSamples':
                chunkDuration.inMicroseconds *
                16000 ~/
                Duration.microsecondsPerSecond,
          },
        );
        if (response is! Map<Object?, Object?>) {
          throw AudioDecodeException('原生持续解码返回格式无效', path: path);
        }
        final Float32List samples = _asFloat32(response['pcm'], path);
        final bool isLast = response['eof'] == true;
        if (samples.isNotEmpty) {
          yield DecodedAudioChunk(samples, isLast: isLast);
        }
        if (isLast) return;
        if (samples.isEmpty) {
          throw AudioDecodeException('原生持续解码未返回采样数据', path: path);
        }
      }
    } on MissingPluginException {
      yield* _decodeLegacyNativeChunks(path, chunkDuration, startAt);
    } on PlatformException catch (error) {
      throw AudioDecodeException(
        '解码失败：${error.message ?? error.code}',
        path: path,
      );
    } finally {
      if (sessionId != null) {
        try {
          await channel.invokeMethod<void>(
            'closePcm16kStream',
            <String, Object?>{'sessionId': sessionId},
          );
        } on Object {
          // 主解码结果优先；关闭失败由原生会话随进程退出释放。
        }
      }
    }
  }

  Stream<DecodedAudioChunk> _decodeLegacyNativeChunks(
    String path,
    Duration chunkDuration,
    Duration startAt,
  ) async* {
    final String extension = p
        .extension(path)
        .replaceFirst('.', '')
        .toLowerCase();
    int startMilliseconds = startAt.inMilliseconds;
    while (true) {
      final Object? response;
      try {
        response = await channel.invokeMethod<Object?>(
          'decodePcm16kChunk',
          <String, Object?>{
            'path': path,
            'startMs': startMilliseconds,
            'durationMs': chunkDuration.inMilliseconds,
          },
        );
      } on MissingPluginException {
        throw AudioDecodeException('当前平台尚未实现 .$extension 的分块解码', path: path);
      } on PlatformException catch (error) {
        throw AudioDecodeException(
          '解码失败：${error.message ?? error.code}',
          path: path,
        );
      }
      if (response is! Map<Object?, Object?>) {
        throw AudioDecodeException('原生分块解码返回格式无效', path: path);
      }
      final Float32List samples = _asFloat32(response['pcm'], path);
      final bool isLast = response['eof'] == true;
      if (samples.isNotEmpty) {
        yield DecodedAudioChunk(samples, isLast: isLast);
      }
      if (isLast) return;
      if (samples.isEmpty) {
        throw AudioDecodeException('原生分块解码未返回采样数据', path: path);
      }
      startMilliseconds += chunkDuration.inMilliseconds;
    }
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
      throw AudioDecodeException(
        '解码失败：${error.message ?? error.code}',
        path: path,
      );
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
    throw AudioDecodeException(
      '原生解码没有返回采样数据（${result.runtimeType}）',
      path: path,
    );
  }
}
