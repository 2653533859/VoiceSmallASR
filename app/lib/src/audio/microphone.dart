/// 麦克风采集：拿到 16 kHz float32 单声道音频块。
///
/// Python 端对应 `audio.iter_microphone()`（sounddevice）。Dart 侧用
/// [`record`](https://pub.dev/packages/record) 包，它在三端都直接给 PCM 流，
/// 不落文件、不经编码器 —— 正好是识别要的形式，只需把 int16 转成 float32。
///
/// 采集必须留在 root isolate（插件的平台通道只在那里可用），因此整条链是：
/// 主 isolate 采集 → `Float32List` 送进识别 isolate → 段回来上屏。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';

/// 麦克风不可用（无权限、无设备、被别的应用占用）。
class MicrophoneException implements Exception {
  const MicrophoneException(this.message);

  final String message;

  @override
  String toString() => 'MicrophoneException: $message';
}

/// 录音源的最小契约。抽出来是为了让界面层能在测试里注入替身音频。
abstract interface class AudioSource {
  /// 开始采集，返回 16 kHz float32 单声道音频块流。
  ///
  /// 无权限或设备不可用时抛 [MicrophoneException]。
  Future<Stream<Float32List>> start();

  /// 停止采集并释放设备。
  Future<void> stop();
}

/// 真正的麦克风。
///
/// 每场录音用一个新的 [AudioRecorder]：`record` 的 `dispose()` 会把平台侧那个
/// 录音器实例销毁，之后同一个对象再 `startStream()` 就失败了 —— 而「开始 → 停止
/// → 再开始」是最常见的用法，所以录音器的生命周期只能是一场录音，不能是本对象。
class MicrophoneSource implements AudioSource {
  MicrophoneSource({AudioRecorder Function()? createRecorder})
    : _create = createRecorder ?? AudioRecorder.new;

  final AudioRecorder Function() _create;
  AudioRecorder? _recorder;

  @override
  Future<Stream<Float32List>> start() async {
    await stop(); // 上一场没收干净时先收掉，避免两个录音器同时占设备
    final AudioRecorder recorder = _create();
    _recorder = recorder;
    try {
      // hasPermission 在 Android/macOS 上会顺带弹出系统授权框（request 默认为 true），
      // 因此不需要再引一层 permission_handler。macOS 还要求 Info.plist 里有
      // NSMicrophoneUsageDescription，缺了会直接崩在系统层。
      final bool granted = await recorder.hasPermission();
      if (!granted) {
        throw const MicrophoneException('没有麦克风权限，请在系统设置里允许本应用使用麦克风');
      }
      final Stream<Uint8List> raw = await recorder.startStream(
        const RecordConfig(
          // 直接要 16 kHz 单声道 PCM：识别模型就要这个规格，省掉重采样与混声道。
          encoder: AudioEncoder.pcm16bits,
          sampleRate: kSampleRate,
          numChannels: 1,
          // 回声消除与降噪交给系统，桌面端外放时能少一些自激。
          echoCancel: true,
          noiseSuppress: true,
        ),
      );
      return raw.map(pcm16ToFloat32);
    } on Object {
      // 开不起来也要把录音器收掉，否则平台侧的实例会一直留着
      _recorder = null;
      await recorder.dispose();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final AudioRecorder? recorder = _recorder;
    _recorder = null;
    if (recorder == null) return;
    await recorder.stop();
    await recorder.dispose();
  }
}

/// int16 小端字节流 → float32 采样（范围 [-1, 1]）。
///
/// 与 `wav.dart` 里 16 位 PCM 的换算保持一致：除以 32768。
Float32List pcm16ToFloat32(Uint8List bytes) {
  final int count = bytes.length ~/ 2;
  final ByteData view = ByteData.sublistView(bytes);
  final Float32List out = Float32List(count);
  for (int i = 0; i < count; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
