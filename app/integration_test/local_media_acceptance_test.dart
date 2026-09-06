/// 本地用户素材技术验收；只输出指标，不记录音视频或识别文本。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' as video;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/project/project_file.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

Future<void> waitFor(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 20)) {
      throw StateError('等待播放器状态超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final path = Platform.environment['VSASR_LOCAL_VIDEO'];
  testWidgets('原始素材：实际位置确认及连续快进后退', (tester) async {
    expect(path, isNotNull, reason: '设置 VSASR_LOCAL_VIDEO');
    final backend = MediaKitVideoPlayerBackend();
    final player = VideoPlaybackController(backend: backend);
    final view = backend.buildVideo() as video.Video;
    addTearDown(player.dispose);
    // 挂载原生播放器以完成纹理初始化，不展示用户视频画面。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Opacity(opacity: 0, child: view)),
      ),
    );
    await tester.pump();
    await view.controller.player.setVolume(0);
    await player.open(path!);
    await waitFor(() => player.duration > const Duration(seconds: 120));
    final measurements = <Map<String, Object>>[];
    for (final seconds in [60, 600, 30]) {
      final watch = Stopwatch()..start();
      await player.seek(Duration(seconds: seconds));
      await waitFor(
        () =>
            !player.seeking &&
            (player.actualPosition.inMilliseconds - seconds * 1000).abs() <
                1000,
      );
      measurements.add({
        'target_seconds': seconds,
        'actual_seconds': player.actualPosition.inMilliseconds / 1000,
        'elapsed_ms': watch.elapsedMilliseconds,
      });
    }
    final base = player.position;
    final requests = <Future<void>>[];
    for (int i = 0; i < 4; i++) {
      requests.add(player.seek(player.position + const Duration(seconds: 10)));
    }
    for (int i = 0; i < 2; i++) {
      requests.add(player.seek(player.position - const Duration(seconds: 10)));
    }
    final target = base + const Duration(seconds: 20);
    await Future.wait(requests);
    await waitFor(
      () =>
          !player.seeking &&
          (player.actualPosition - target).abs() < const Duration(seconds: 1),
    );
    final burstActual = player.actualPosition;
    // 在静音播放状态下验证连续跳转，避免播放用户素材的声音。
    await player.playOrPause();
    await waitFor(() => player.playing && player.actualPosition > target);
    final playingBase = player.position;
    final forward1 = player.seek(player.position + const Duration(seconds: 10));
    final forward2 = player.seek(player.position + const Duration(seconds: 10));
    final backward = player.seek(player.position - const Duration(seconds: 10));
    final playingTarget = playingBase + const Duration(seconds: 10);
    await Future.wait([forward1, forward2, backward]);
    await waitFor(
      () =>
          !player.seeking &&
          (player.actualPosition - playingTarget).abs() <
              const Duration(seconds: 1),
    );
    expect(player.playing, isTrue);
    final playingActual = player.actualPosition;
    await player.playOrPause();
    await waitFor(() => !player.playing);
    // ignore: avoid_print
    print(
      'PLAYBACK_METRICS ${jsonEncode({'duration_seconds': player.duration.inSeconds, 'seeks': measurements, 'burst_expected': target.inMilliseconds / 1000, 'burst_actual': burstActual.inMilliseconds / 1000, 'playing_expected': playingTarget.inMilliseconds / 1000, 'playing_actual': playingActual.inMilliseconds / 1000})}',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
  });

  test('原始素材：选区语言与增益对比、预览保护及撤销', () async {
    expect(path, isNotNull);
    const source = TranscriptionResult(
      duration: 20,
      segments: [Segment(text: '保留字幕', start: 0, end: 1)],
    );
    final controller = TranscribeController(offlineMode: true);
    addTearDown(controller.shutdown);
    await controller.loadProject(
      VsasrProject(mediaPath: path, config: AsrConfig(), result: source),
    );
    final metrics = <Map<String, Object>>[];
    for (final config in [
      AsrConfig(),
      AsrConfig(language: 'ja'),
      AsrConfig(
        language: 'ja',
        inputGainDb: 6,
        vad: const VadConfig(
          threshold: .35,
          minSilenceDuration: .5,
          minSpeechDuration: .15,
        ),
      ),
    ]) {
      final watch = Stopwatch()..start();
      final segments = await controller.previewRange(
        start: 24,
        end: 45,
        mediaDuration: 120,
        config: config,
      );
      expect(controller.result, same(source));
      expect(segments, isNotEmpty);
      expect(segments.every((s) => s.start >= 24 && s.end <= 45), isTrue);
      metrics.add({
        'language': config.language,
        'gain_db': config.inputGainDb,
        'elapsed_ms': watch.elapsedMilliseconds,
        'segments': segments.length,
        'characters': segments.fold<int>(0, (n, s) => n + s.text.runes.length),
        'languages': segments.map((s) => s.language).toSet().toList(),
        'speech_seconds': segments.fold<double>(
          0,
          (n, s) => n + s.end - s.start,
        ),
      });
      final editor = SubtitleEditorController(initial: source);
      editor.replaceRange(24, 45, segments, mediaDuration: 120);
      expect(editor.result.segments.first.text, '保留字幕');
      editor.undo();
      expect(editor.result.segments.length, 1);
      editor.dispose();
    }
    // ignore: avoid_print
    print('ASR_METRICS ${jsonEncode(metrics)}');
  });
}
