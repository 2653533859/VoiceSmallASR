/// Windows 桌面运行时 smoke：不依赖 ASR 模型，直接验证平台原生音频解码和播放器。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late String audioPath;
  late String videoPath;

  setUpAll(() {
    audioPath = _requiredEnvironment('VSASR_SMOKE_AUDIO');
    videoPath = _requiredEnvironment('VSASR_SMOKE_VIDEO');
  });

  test('Windows Media Foundation 解码 AAC 音频', () async {
    final File audio = File(audioPath);
    expect(audio.existsSync(), isTrue, reason: '测试音频不存在：$audioPath');

    final List<double> samples = await const PlatformAudioDecoder().decodeFile(audioPath);
    expect(samples.length, greaterThan(16000));
    expect(samples.any((double value) => value.abs() > 0.01), isTrue, reason: '解码结果不应是静音');
  });

  testWidgets('Windows media_kit 可以打开、读取时长并播放 MP4', (WidgetTester tester) async {
    final File video = File(videoPath);
    expect(video.existsSync(), isTrue, reason: '测试视频不存在：$videoPath');

    final VideoPlaybackController player = VideoPlaybackController();
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: player.buildVideo()),
      ),
    );
    await tester.pump();

    await player.open(videoPath);
    await _waitUntil(
      () => player.duration > const Duration(seconds: 1),
      reason: 'media_kit 没有从真实 MP4 读取到视频时长',
    );
    expect(player.duration, greaterThan(const Duration(seconds: 1)));

    await player.playOrPause();
    await _waitUntil(
      () => player.position > Duration.zero,
      reason: '真实 MP4 没有开始播放',
    );
    await player.playOrPause();
  });
}

String _requiredEnvironment(String name) {
  final String? value = Platform.environment[name]?.trim();
  if (value == null || value.isEmpty) {
    fail('缺少 Windows smoke 测试环境变量：$name');
  }
  return value;
}

Future<void> _waitUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed >= timeout) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
