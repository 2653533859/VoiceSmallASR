/// 音频解码入口测试：wav 走纯 Dart、其余走原生通道的分发逻辑。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';

import 'support/wav_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('vsasr_decode_test');
    calls.clear();
  });

  tearDown(() {
    workspace.deleteSync(recursive: true);
    _mock(null, calls);
  });

  File writeFile(String name, List<int> bytes) {
    final File file = File('${workspace.path}/$name')..writeAsBytesSync(bytes);
    return file;
  }

  test('wav 走纯 Dart，不碰平台通道', () async {
    _mock((MethodCall call) async => throw StateError('wav 不应走原生通道'), calls);
    final File file = writeFile(
      'a.wav',
      buildWav(
        frames: <List<double>>[
          <double>[0.5],
          <double>[-0.5],
        ],
      ),
    );
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(
      file.path,
    );
    expect(samples.length, 2);
    expect(calls, isEmpty);
  });

  test('扩展名大写同样按 wav 处理', () async {
    final File file = writeFile(
      'B.WAV',
      buildWav(
        frames: <List<double>>[
          <double>[0.25],
        ],
      ),
    );
    expect(
      (await const PlatformAudioDecoder().decodeFile(file.path)).length,
      1,
    );
  });

  test('压缩格式转交原生通道，并带上绝对路径', () async {
    _mock(
      (MethodCall call) async => Float32List.fromList(<double>[0.1, 0.2, 0.3]),
      calls,
    );
    final File file = writeFile('a.mp3', <int>[0, 1, 2, 3]);
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(
      file.path,
    );
    expect(samples.length, 3);
    expect(samples[0], closeTo(0.1, 1e-6));
    expect(samples[1], closeTo(0.2, 1e-6));
    expect(samples[2], closeTo(0.3, 1e-6));
    expect(calls.single.method, 'decodeToPcm16k');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['path'],
      file.path,
    );
  });

  test('视频容器也走原生（只取音轨）', () async {
    _mock(
      (MethodCall call) async => Float32List.fromList(<double>[0.0]),
      calls,
    );
    final File file = writeFile('movie.mp4', <int>[0, 0, 0, 0]);
    expect(
      (await const PlatformAudioDecoder().decodeFile(file.path)).length,
      1,
    );
    expect(calls.single.method, 'decodeToPcm16k');
  });

  test('视频分块解码逐块请求且在 eof 后停止', () async {
    var index = 0;
    _mock((MethodCall call) async {
      index++;
      return <String, Object>{
        'pcm': Float32List.fromList(<double>[index.toDouble()]),
        'eof': index == 2,
      };
    }, calls);
    final File file = writeFile('movie.mp4', <int>[0, 0, 0, 0]);

    final List<DecodedAudioChunk> chunks = await const PlatformAudioDecoder()
        .decodeFileChunks(file.path, chunkDuration: const Duration(seconds: 3))
        .toList();

    expect(
      chunks.map((DecodedAudioChunk chunk) => chunk.samples.single),
      <double>[1, 2],
    );
    expect(chunks.last.isLast, isTrue);
    expect(calls.map((MethodCall call) => call.method).toSet(), <String>{
      'decodePcm16kChunk',
    });
    expect(
      calls.map((MethodCall call) => (call.arguments as Map)['startMs']),
      <int>[0, 3000],
    );
  });

  test('原生按字节回传时也能解出 float32', () async {
    final ByteData raw = ByteData(8)
      ..setFloat32(0, 0.5, Endian.little)
      ..setFloat32(4, -0.25, Endian.little);
    _mock((MethodCall call) async => raw.buffer.asUint8List(), calls);
    final File file = writeFile('a.m4a', <int>[1]);
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(
      file.path,
    );
    expect(samples[0], closeTo(0.5, 1e-6));
    expect(samples[1], closeTo(-0.25, 1e-6));
  });

  test('平台未实现原生解码时给出可执行的中文提示', () async {
    // 不注册 mock handler，invokeMethod 会抛 MissingPluginException
    final File file = writeFile('a.flac', <int>[1, 2]);
    await expectLater(
      const PlatformAudioDecoder().decodeFile(file.path),
      throwsA(
        isA<AudioDecodeException>().having(
          (AudioDecodeException e) => e.message,
          'message',
          allOf(contains('flac'), contains('wav')),
        ),
      ),
    );
  });

  test('原生解码报错时转成 AudioDecodeException', () async {
    _mock(
      (MethodCall call) async =>
          throw PlatformException(code: 'DECODE_FAILED', message: '音轨为空'),
      calls,
    );
    final File file = writeFile('a.mp3', <int>[1]);
    await expectLater(
      const PlatformAudioDecoder().decodeFile(file.path),
      throwsA(
        isA<AudioDecodeException>().having(
          (AudioDecodeException e) => e.message,
          'message',
          contains('音轨为空'),
        ),
      ),
    );
  });

  test('原生什么都没返回时报错，而不是回一段空音频', () async {
    _mock((MethodCall call) async => null, calls);
    final File file = writeFile('a.mp3', <int>[1]);
    await expectLater(
      const PlatformAudioDecoder().decodeFile(file.path),
      throwsA(isA<AudioDecodeException>()),
    );
  });

  test('扩展名是 wav 但内容是压缩编码时退回原生', () async {
    _mock(
      (MethodCall call) async => Float32List.fromList(<double>[0.9]),
      calls,
    );
    // format=2（ADPCM）：纯 Dart 解不了，应转交原生而不是直接失败
    final File file = writeFile(
      'weird.wav',
      buildWav(
        frames: <List<double>>[
          <double>[0.5],
        ],
        format: 2,
      ),
    );
    expect(
      (await const PlatformAudioDecoder().decodeFile(file.path)).length,
      1,
    );
    expect(calls.single.method, 'decodeToPcm16k');
  });

  test('文件不存在时立刻报错，不发通道调用', () async {
    _mock((MethodCall call) async => throw StateError('不应调用'), calls);
    await expectLater(
      const PlatformAudioDecoder().decodeFile('${workspace.path}/missing.mp3'),
      throwsA(isA<AudioDecodeException>()),
    );
    expect(calls, isEmpty);
  });

  test('文件选择白名单同时覆盖 wav 与视频容器', () {
    expect(kSupportedAudioExtensions, contains('wav'));
    expect(kSupportedAudioExtensions, contains('mp4'));
    expect(kSupportedAudioExtensions, contains('m4a'));
    expect(
      kSupportedAudioExtensions.toSet().length,
      kSupportedAudioExtensions.length,
    );
  });
}

/// 注册（或传 null 注销）原生通道的替身，并记录收到的调用。
void _mock(
  Future<Object?> Function(MethodCall call)? handler,
  List<MethodCall> calls,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        kAudioDecoderChannel,
        handler == null
            ? null
            : (MethodCall call) {
                calls.add(call);
                return handler(call);
              },
      );
}
