/// 真实播放器内嵌字幕轨验收。
///
/// ```bash
/// VSASR_EMBEDDED_SUBTITLE_VIDEO=/path/to/video.mkv \
/// flutter test integration_test/embedded_subtitle_acceptance_test.dart -d macos
/// ```
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('真实 media_kit 后端枚举、选择并关闭内嵌字幕轨', (tester) async {
    const defined = String.fromEnvironment('VSASR_EMBEDDED_SUBTITLE_VIDEO');
    final configured = defined.trim().isNotEmpty
        ? defined
        : Platform.environment['VSASR_EMBEDDED_SUBTITLE_VIDEO'] ?? '';
    if (configured.trim().isEmpty) {
      markTestSkipped('未提供 VSASR_EMBEDDED_SUBTITLE_VIDEO');
      return;
    }
    final file = File(configured);
    expect(file.existsSync(), isTrue, reason: configured);
    final backend = MediaKitVideoPlayerBackend();
    final controller = VideoPlaybackController(backend: backend);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Opacity(opacity: 0, child: backend.buildVideo())),
      ),
    );
    await tester.pump();
    await controller.open(file.path);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (controller.embeddedSubtitleTracks.isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(controller.errorText, isNull);
    expect(controller.embeddedSubtitleTracks, isNotEmpty);
    final track = controller.embeddedSubtitleTracks.first;
    await controller.selectEmbeddedSubtitleTrack(track.id);
    expect(controller.selectedEmbeddedSubtitleTrackId, track.id);
    await controller.selectEmbeddedSubtitleTrack(null);
    expect(controller.selectedEmbeddedSubtitleTrackId, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(minutes: 2)));
}
