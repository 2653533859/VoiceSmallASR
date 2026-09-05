/// 麦克风采集的测试。用替身录音器，不碰真设备也不需要插件。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/audio/microphone.dart';

void main() {
  for (final bool hangs in <bool>[false, true]) {
    test('stop ${hangs ? '挂起' : '抛异常'}仍调用 dispose 并有界返回', () async {
      final _FailingRecorder recorder = _FailingRecorder(hangs);
      final MicrophoneSource mic = MicrophoneSource(
        createRecorder: () => recorder,
        operationTimeout: const Duration(milliseconds: 20),
      );
      await mic.start();
      await expectLater(
        mic.stop().timeout(const Duration(seconds: 1)),
        throwsA(hangs ? isA<TimeoutException>() : isA<StateError>()),
      );
      expect(recorder.disposed, isTrue);
      await mic.stop();
    });
  }

  test('int16 小端 → float32：按 32768 归一，与 wav.dart 一致', () {
    final Uint8List bytes = Uint8List.fromList(<int>[
      0x00, 0x00, // 0
      0x00, 0x40, // 16384 → 0.5
      0x00, 0xC0, // -16384 → -0.5
      0x00, 0x80, // -32768 → -1.0
    ]);
    final Float32List out = pcm16ToFloat32(bytes);
    expect(out, hasLength(4));
    expect(out[0], 0.0);
    expect(out[1], closeTo(0.5, 1e-9));
    expect(out[2], closeTo(-0.5, 1e-9));
    expect(out[3], closeTo(-1.0, 1e-9));
  });

  test('开始录音：要 16 kHz 单声道 PCM16，并把字节流转成采样流', () async {
    final _FakeRecorder recorder = _FakeRecorder();
    final MicrophoneSource mic = MicrophoneSource(
      createRecorder: () => recorder,
    );

    final Stream<Float32List> audio = await mic.start();
    final Future<List<Float32List>> collected = audio.toList();

    expect(recorder.config?.encoder, AudioEncoder.pcm16bits);
    expect(recorder.config?.sampleRate, kSampleRate);
    expect(recorder.config?.numChannels, 1);

    recorder.push(Uint8List.fromList(<int>[0x00, 0x40, 0x00, 0xC0]));
    await recorder.closeStream();
    expect((await collected).single, hasLength(2));

    await mic.stop();
    expect(recorder.stopped, isTrue);
    expect(recorder.disposed, isTrue);
  });

  // 回归：录音器 dispose 之后平台侧的实例就没了，再 startStream 会失败。
  // 「开始 → 停止 → 再开始」是最常见的用法，每场必须换一个新的录音器。
  test('停止后可以再开一场，用的是新的录音器', () async {
    final List<_FakeRecorder> made = <_FakeRecorder>[];
    final MicrophoneSource mic = MicrophoneSource(
      createRecorder: () {
        final _FakeRecorder r = _FakeRecorder();
        made.add(r);
        return r;
      },
    );

    await mic.start();
    await mic.stop();
    await mic.start();
    await mic.stop();

    expect(made, hasLength(2));
    expect(made.every((_FakeRecorder r) => r.disposed), isTrue);
    // 第二场不能用已经 dispose 掉的那个
    expect(identical(made[0], made[1]), isFalse);
  });

  test('没权限时抛中文异常，并把录音器收掉', () async {
    final _FakeRecorder recorder = _FakeRecorder(granted: false);
    final MicrophoneSource mic = MicrophoneSource(
      createRecorder: () => recorder,
    );

    await expectLater(
      mic.start(),
      throwsA(
        isA<MicrophoneException>().having(
          (MicrophoneException e) => e.message,
          'message',
          contains('麦克风权限'),
        ),
      ),
    );
    expect(recorder.disposed, isTrue);
    // 失败之后 stop() 不该再去动那个已经收掉的录音器
    await mic.stop();
    expect(recorder.stopCalls, 0);
  });

  test('没开起来就 stop 是安全的', () async {
    final MicrophoneSource mic = MicrophoneSource(
      createRecorder: _FakeRecorder.new,
    );
    await mic.stop();
  });
}

/// 替身录音器。`AudioRecorder` 的公开面很大，这里只实现用到的四个方法，
/// 其余交给 [noSuchMethod]（碰到了就会在测试里立刻炸出来）。
class _FakeRecorder implements AudioRecorder {
  _FakeRecorder({this.granted = true});

  final bool granted;
  final StreamController<Uint8List> _out = StreamController<Uint8List>();

  RecordConfig? config;
  bool disposed = false;
  int stopCalls = 0;

  bool get stopped => stopCalls > 0;

  void push(Uint8List bytes) => _out.add(bytes);

  Future<void> closeStream() => _out.close();

  @override
  Future<bool> hasPermission({bool request = true}) async => granted;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    this.config = config;
    return _out.stream;
  }

  @override
  Future<String?> stop() async {
    stopCalls++;
    return null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    // 不能 await：没人监听时 close() 的 Future 永远不会完成
    if (!_out.isClosed) unawaited(_out.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('替身没实现 ${invocation.memberName}');
}

class _FailingRecorder extends _FakeRecorder {
  _FailingRecorder(this.hangs);
  final bool hangs;
  @override
  Future<String?> stop() {
    if (hangs) return Completer<String?>().future;
    throw StateError('stop failed');
  }
}
