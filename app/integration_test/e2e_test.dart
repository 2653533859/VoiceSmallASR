/// 端到端验收：真模型、真引擎、真原生解码，在真实设备/桌面上跑。
///
/// 与 `test/` 下的单测不同，这里**不用任何替身** —— 目的就是验证
/// 「Flutter 端与 Python 端逐字一致」这条 M1 验收标准。
///
/// 跑法（macOS）：
/// ```bash
/// flutter test integration_test/e2e_test.dart -d macos
/// ```
/// 依赖模型已在应用私有目录里；缺模型时整组自动跳过。
/// 沙盒应用只能读自己的容器，因此素材要放在模型目录内的 `test_wavs/`
/// （模型压缩包自带该目录，`yue.m4a` 与 `en.mp4` 由外部用 ffmpeg 生成后放进去）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';
import 'package:vsasr_app/src/asr/transcription_worker.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_timeline.dart';

/// Python 端在本机跑出的基准（见 DEVELOPMENT_PLAN.md §1）。
const String kYueBaseline = '呢几个字都表达唔到，我想讲嘅意思。';

/// Python 端 `audio.load()` 对 yue.wav 得到的采样数。
const int kYueSamples = 82368;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late ModelPaths paths;
  late String wavs;

  setUpAll(() async {
    paths = await ModelManager().resolvePaths();
    wavs = p.join(p.dirname(paths.asrModel), 'test_wavs');
  });

  test('模型在应用私有目录里就绪', () {
    expect(
      paths.exists,
      isTrue,
      reason: '模型不在 ${paths.root}，先在界面上下载，或从 Python 端的缓存拷进去',
    );
  });

  test('纯 Dart 读 wav：采样数与 Python 端一致', () async {
    final String path = p.join(wavs, 'yue.wav');
    if (!File(path).existsSync()) {
      markTestSkipped('缺 $path');
      return;
    }
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(path);
    expect(samples.length, kYueSamples);
  });

  test('原生解码 m4a：走通 vsasr/audio_decoder 通道', () async {
    final String path = p.join(wavs, 'yue.m4a');
    if (!File(path).existsSync()) {
      markTestSkipped('缺 $path（用 ffmpeg 从 yue.wav 转一个放进去）');
      return;
    }
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(path);
    // AAC 编码器会补前导静音，长度不会与 wav 完全相同，但必须同量级
    expect(samples.length, greaterThan(kYueSamples - 4096));
    expect(samples.length, lessThan(kYueSamples + 8192));
    expect(samples.any((double v) => v.abs() > 0.01), isTrue, reason: '解出来不该是一段静音');
  });

  test('识别 yue.wav：与 Python 端逐字一致', () async {
    if (!paths.exists) {
      markTestSkipped('模型缺失');
      return;
    }
    final String path = p.join(wavs, 'yue.wav');
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(path);

    final TranscriptionWorker worker = await TranscriptionWorker.start(
      config: AsrConfig(language: 'yue'),
      allowDownload: false,
    );
    addTearDown(worker.dispose);

    final Stopwatch watch = Stopwatch()..start();
    final TranscriptionResult result = await worker.transcribe(samples);
    final double rtf = watch.elapsedMilliseconds / 1000 / result.duration;

    // ignore: avoid_print
    print('识别结果：${result.text}　RTF ${rtf.toStringAsFixed(3)}');
    expect(result.text, kYueBaseline);
    expect(result.length, 1);
    final Segment segment = result.segments.single;
    // 粤语用字必须保留，这是选型的验证点
    expect(segment.text, allOf(contains('呢'), contains('唔'), contains('嘅')));
    expect(segment.words, isNotEmpty, reason: 'token 级时间戳不该为空');
    expect(segment.start, greaterThanOrEqualTo(0));
    expect(segment.end, lessThanOrEqualTo(result.duration + 0.001));
  });

  test('识别 m4a（原生解码 + 引擎）：粤语用字同样保留', () async {
    final String path = p.join(wavs, 'yue.m4a');
    if (!paths.exists || !File(path).existsSync()) {
      markTestSkipped('模型或 m4a 缺失');
      return;
    }
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(path);
    final TranscriptionWorker worker = await TranscriptionWorker.start(
      config: AsrConfig(language: 'yue'),
      allowDownload: false,
    );
    addTearDown(worker.dispose);

    final TranscriptionResult result = await worker.transcribe(samples);
    // ignore: avoid_print
    print('m4a 识别结果：${result.text}');
    expect(result.text, allOf(contains('呢'), contains('唔'), contains('嘅')));
  });

  testWidgets('真实 mp4：播放器读取、跳转与视频音轨识别都可用', (WidgetTester tester) async {
    final String path = p.join(wavs, 'en.mp4');
    if (!paths.exists || !File(path).existsSync()) {
      markTestSkipped('模型或 mp4 缺失：按 DEVELOPMENT_PLAN.md §7 生成 en.mp4');
      return;
    }

    // 同一个 mp4 同时走播放器与 M1 的视频抽音轨路径，避免只测到其中一条链路。
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(path);
    final TranscriptionWorker worker = await TranscriptionWorker.start(
      config: AsrConfig(language: 'en'),
      allowDownload: false,
    );
    addTearDown(worker.dispose);
    final TranscriptionResult result = await worker.transcribe(samples);
    expect(result.text, allOf(contains('tribal chieftain'), contains('gold')));

    final VideoPlaybackController player = VideoPlaybackController();
    addTearDown(player.dispose);
    // media_kit 的 VideoController 要等 Flutter 首帧完成初始化；集成测试也要真实挂载 Video。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: player.buildVideo()),
      ),
    );
    await tester.pump();
    await player.open(path);
    await _waitUntil(
      () => player.duration > const Duration(seconds: 1),
      reason: 'media_kit 没有从真实 mp4 读到视频时长',
    );
    expect(player.duration, greaterThan(const Duration(seconds: 4)));

    final Segment segment = result.segments.firstWhere((Segment value) => value.text.trim().isNotEmpty);
    final Duration cuePosition = Duration(
      microseconds: (((segment.start + segment.end) / 2) * Duration.microsecondsPerSecond).round(),
    );
    expect(activeSegment(result.segments, cuePosition)?.text, segment.text);

    await player.seek(cuePosition);
    await _waitUntil(
      () => (player.position.inMicroseconds - cuePosition.inMicroseconds).abs() <
          const Duration(milliseconds: 250).inMicroseconds,
      reason: '播放器跳转后位置没有落在字幕时间范围附近',
    );

    await player.playOrPause();
    await _waitUntil(
      () => player.position > cuePosition,
      reason: '真实 mp4 没有开始播放',
    );
    await player.playOrPause();
  });

  // M2 验收：麦克风那一路没法自动化（要真人说话），但麦克风之后的整条链路
  // 与这里完全相同 —— 100 ms 一块的 16 kHz float32 喂进实时会话。
  // 用三段素材拼出「说三句话」，验证三句都定稿且时间戳连续。
  test('实时识别：三句话都定稿，时间戳连续不重叠', () async {
    if (!paths.exists) {
      markTestSkipped('模型缺失');
      return;
    }
    const List<String> sources = <String>['zh.wav', 'en.wav', 'yue.wav'];
    for (final String name in sources) {
      if (!File(p.join(wavs, name)).existsSync()) {
        markTestSkipped('缺 ${p.join(wavs, name)}');
        return;
      }
    }

    // 句间垫 0.8 秒静音：VAD 要听到 minSilenceDuration(0.35s) 才判定一句说完
    final List<Float32List> parts = <Float32List>[];
    for (final String name in sources) {
      parts.add(await const PlatformAudioDecoder().decodeFile(p.join(wavs, name)));
      parts.add(Float32List((0.8 * kSampleRate).round()));
    }
    final Float32List audio = _concat(parts);

    final TranscriptionWorker worker = await TranscriptionWorker.start(allowDownload: false);
    addTearDown(worker.dispose);

    final LiveSession session = await worker.startLive();
    final List<Segment> finals = <Segment>[];
    final List<Segment> partials = <Segment>[];
    session.segments.listen((Segment s) => (s.isFinal ? finals : partials).add(s));

    // 按 100 ms 一块推进，模拟麦克风的节奏
    const int chunk = kSampleRate ~/ 10;
    for (int offset = 0; offset < audio.length; offset += chunk) {
      final int end = (offset + chunk) < audio.length ? offset + chunk : audio.length;
      session.accept(Float32List.sublistView(audio, offset, end));
      // 让识别 isolate 有机会处理这一块（真实录音时是自然到达的）
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await session.finish();

    // ignore: avoid_print
    print('实时定稿 ${finals.length} 句、局部 ${partials.length} 条：'
        '${finals.map((Segment s) => s.text).join(' / ')}');

    expect(finals.length, greaterThanOrEqualTo(3), reason: '三句话应各自定稿');
    expect(partials, isNotEmpty, reason: '说话过程中应有局部结果上屏');
    for (int i = 0; i < finals.length; i++) {
      expect(finals[i].text, isNotEmpty);
      expect(finals[i].index, i, reason: '定稿序号必须从 0 连续递增');
      expect(finals[i].end, greaterThan(finals[i].start));
      if (i > 0) {
        expect(
          finals[i].start,
          greaterThanOrEqualTo(finals[i - 1].end),
          reason: '时间戳不能倒序或重叠',
        );
      }
    }
    expect(partials.every((Segment s) => s.index == -1), isTrue);
  });
}

/// 把若干块音频首尾相接。
Float32List _concat(List<Float32List> parts) {
  final int total = parts.fold(0, (int sum, Float32List p) => sum + p.length);
  final Float32List out = Float32List(total);
  int offset = 0;
  for (final Float32List part in parts) {
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}

Future<void> _waitUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed >= timeout) {
      fail(reason);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
