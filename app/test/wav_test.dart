/// 纯 Dart WAV 解码器测试。不需要模型、不需要设备，`flutter test` 直接可跑。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/audio/wav.dart';

import 'support/wav_builder.dart';

/// 16 位量化的误差上限：1/32768 ≈ 3.05e-5。
const double kPcm16Tolerance = 1 / 32768 + 1e-9;

void main() {
  group('decodeWav', () {
    test('16 位单声道原样读出', () {
      final List<double> wanted = <double>[0.0, 0.5, -0.5, 0.25];
      final WavData wav = decodeWav(
        buildWav(frames: wanted.map((double v) => <double>[v]).toList()),
      );
      expect(wav.sampleRate, 16000);
      expect(wav.channels, 1);
      expect(wav.samples.length, wanted.length);
      for (int i = 0; i < wanted.length; i++) {
        expect(wav.samples[i], closeTo(wanted[i], kPcm16Tolerance));
      }
    });

    test('多声道按算术平均混成单声道（与 Python 端 mean(axis=1) 一致）', () {
      final WavData wav = decodeWav(
        buildWav(
          frames: <List<double>>[
            <double>[1.0, -1.0],
            <double>[0.5, 0.5],
            <double>[0.25, -0.75],
          ],
        ),
      );
      expect(wav.channels, 2);
      expect(wav.samples.length, 3);
      expect(wav.samples[0], closeTo(0.0, kPcm16Tolerance));
      expect(wav.samples[1], closeTo(0.5, kPcm16Tolerance));
      expect(wav.samples[2], closeTo(-0.25, kPcm16Tolerance));
    });

    test('8 位按无符号解读，128 为静音', () {
      final WavData wav = decodeWav(
        buildWav(
          frames: <List<double>>[
            <double>[0.0],
            <double>[0.5],
            <double>[-0.5],
          ],
          bitsPerSample: 8,
        ),
      );
      expect(wav.samples[0], closeTo(0.0, 1 / 128));
      expect(wav.samples[1], closeTo(0.5, 1 / 128));
      expect(wav.samples[2], closeTo(-0.5, 1 / 128));
    });

    test('24 位做符号扩展，负值不会变成大正数', () {
      final WavData wav = decodeWav(
        buildWav(
          frames: <List<double>>[
            <double>[-0.75],
            <double>[0.75],
          ],
          bitsPerSample: 24,
        ),
      );
      expect(wav.samples[0], closeTo(-0.75, 1e-6));
      expect(wav.samples[1], closeTo(0.75, 1e-6));
    });

    test('32 位整型 PCM', () {
      final WavData wav = decodeWav(
        buildWav(frames: <List<double>>[<double>[-0.5], <double>[0.5]], bitsPerSample: 32),
      );
      expect(wav.samples[0], closeTo(-0.5, 1e-7));
      expect(wav.samples[1], closeTo(0.5, 1e-7));
    });

    test('32 位浮点原样读出', () {
      final WavData wav = decodeWav(
        buildWav(
          frames: <List<double>>[<double>[0.123456], <double>[-0.98]],
          bitsPerSample: 32,
          format: wavFormatFloat,
        ),
      );
      expect(wav.samples[0], closeTo(0.123456, 1e-6));
      expect(wav.samples[1], closeTo(-0.98, 1e-6));
    });

    test('WAVE_FORMAT_EXTENSIBLE 从 SubFormat 里取真实编码', () {
      final WavData wav = decodeWav(
        buildWav(
          frames: <List<double>>[<double>[0.5]],
          format: wavFormatExtensible,
          subFormat: wavFormatPcm,
        ),
      );
      expect(wav.samples[0], closeTo(0.5, kPcm16Tolerance));
    });

    test('跳过不认识的 chunk（LIST/fact 等）', () {
      final WavData wav = decodeWav(
        buildWav(
          frames: <List<double>>[<double>[0.5], <double>[-0.5]],
          // 奇数长度，顺带验证 chunk 的偶数字节对齐
          extraChunks: <int>[...filler('LIST', 7), ...filler('fact', 4)],
        ),
      );
      expect(wav.samples.length, 2);
      expect(wav.samples[0], closeTo(0.5, kPcm16Tolerance));
    });

    test('data 的 size 写成 0 时读到文件末尾（流式写入的 wav）', () {
      final WavData wav = decodeWav(
        buildWav(
          frames: <List<double>>[<double>[0.5], <double>[-0.5], <double>[0.25]],
          dataSizeOverride: 0,
        ),
      );
      expect(wav.samples.length, 3);
    });

    // 回归：曾经按**声明的** size 前进，size 为 0 时等于原地不动，
    // 于是 PCM 数据被当成 chunk 头继续解析，只要采样字节恰好拼出 'data'
    // 就会把 data 改指到后面一小片，静默丢掉前半段音频。
    test('data 的 size 为 0 且采样字节恰好拼出 data 时不丢音频', () {
      // 16 位 PCM 下这两个值编码出来正是 'd''a' 与 't''a'，
      // 紧跟两个 0 采样又正好被读成「size = 0」。
      const double d = 24932 / 32768; // 0x61 0x64 → 'd' 'a'
      const double t = 24948 / 32768; // 0x61 0x74 → 't' 'a'
      final WavData wav = decodeWav(
        buildWav(
          frames: <List<double>>[
            <double>[d],
            <double>[t],
            <double>[0],
            <double>[0],
            <double>[0.5],
            <double>[-0.5],
            <double>[0.25],
            <double>[-0.25],
          ],
          dataSizeOverride: 0,
        ),
      );
      expect(wav.samples.length, 8);
      expect(wav.samples.first, closeTo(d, kPcm16Tolerance));
    });

    test('data 的 size 超出实际长度时按实际长度截断，不越界', () {
      final WavData wav = decodeWav(
        buildWav(frames: <List<double>>[<double>[0.5]], dataSizeOverride: 1 << 20),
      );
      expect(wav.samples.length, 1);
    });

    test('缺少 RIFF/WAVE 头时报错', () {
      expect(
        () => decodeWav(buildWav(frames: <List<double>>[<double>[0.0]], riffTag: 'RIFX')),
        throwsA(isA<WavFormatException>()),
      );
      expect(
        () => decodeWav(buildWav(frames: <List<double>>[<double>[0.0]], waveTag: 'AVI ')),
        throwsA(isA<WavFormatException>()),
      );
    });

    test('文件过短时报错而不是越界', () {
      expect(() => decodeWav(Uint8List(6)), throwsA(isA<WavFormatException>()));
    });

    test('缺 fmt 或缺 data 时报错', () {
      expect(
        () => decodeWav(buildWav(frames: <List<double>>[<double>[0.0]], includeFmt: false)),
        throwsA(isA<WavFormatException>()),
      );
      expect(
        () => decodeWav(buildWav(frames: <List<double>>[<double>[0.0]], includeData: false)),
        throwsA(isA<WavFormatException>()),
      );
    });

    test('压缩编码（如 ADPCM）明确报不支持', () {
      expect(
        () => decodeWav(buildWav(frames: <List<double>>[<double>[0.0]], format: 2)),
        throwsA(isA<WavFormatException>()),
      );
    });
  });

  group('resampleLinear', () {
    test('采样率相同时原样返回，不做任何插值', () {
      final Float32List input = Float32List.fromList(<double>[0.1, 0.2, 0.3]);
      expect(resampleLinear(input, 16000, 16000), same(input));
    });

    test('降采样后长度按比例缩短', () {
      final Float32List input = Float32List(32000);
      expect(resampleLinear(input, 32000, 16000).length, 16000);
    });

    test('升采样后长度按比例变长', () {
      final Float32List input = Float32List(8000);
      expect(resampleLinear(input, 8000, 16000).length, 16000);
    });

    test('线性插值取中点', () {
      final Float32List input = Float32List.fromList(<double>[0.0, 1.0]);
      final Float32List out = resampleLinear(input, 1, 2);
      expect(out.length, 4);
      expect(out[0], closeTo(0.0, 1e-6));
      expect(out[1], closeTo(0.5, 1e-6));
    });

    test('空输入与非法采样率', () {
      expect(resampleLinear(Float32List(0), 8000, 16000).length, 0);
      expect(() => resampleLinear(Float32List(4), 0, 16000), throwsArgumentError);
    });
  });

  group('decodeWavToModelInput', () {
    test('16 kHz 素材不经过重采样', () {
      final Uint8List bytes = buildWav(
        frames: List<List<double>>.generate(100, (int i) => <double>[i / 200]),
      );
      expect(decodeWavToModelInput(bytes).length, 100);
    });

    test('8 kHz 素材被重采样到 16 kHz', () {
      final Uint8List bytes = buildWav(
        frames: List<List<double>>.generate(800, (int i) => <double>[0.0]),
        sampleRate: 8000,
      );
      expect(decodeWavToModelInput(bytes).length, 1600);
    });
  });

  group('模型自带的 test_wavs（缺失则跳过）', () {
    test('yue.wav 解出的采样数与文件头自洽', () {
      final File? sample = _findSampleWav('yue.wav');
      if (sample == null) {
        markTestSkipped('未找到模型自带示例音频，先在 Python 端跑 uv run vsasr download');
        return;
      }
      final WavData wav = decodeWav(sample.readAsBytesSync());
      expect(wav.sampleRate, 16000, reason: 'sherpa-onnx 的示例音频固定 16 kHz 单声道');
      expect(wav.channels, 1);
      // 16 位单声道：采样数 = data 字节数 / 2。文件头 44 字节是标准 canonical WAV。
      expect(wav.samples.length, (sample.lengthSync() - 44) ~/ 2);
      expect(wav.duration, greaterThan(1.0));
    });
  });
}

/// 在 Python 端的模型缓存里找示例音频，找不到返回 null。
File? _findSampleWav(String name) {
  const String modelName = 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17';
  final String? override = Platform.environment['VSASR_MODEL_DIR'];
  final String? home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final List<String> roots = <String>[
    ?override,
    if (home != null) '$home/.cache/voice-small-asr/models',
  ];
  for (final String root in roots) {
    final File candidate = File('$root/$modelName/test_wavs/$name');
    if (candidate.existsSync()) return candidate;
  }
  return null;
}
