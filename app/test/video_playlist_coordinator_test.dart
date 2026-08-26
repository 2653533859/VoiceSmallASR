import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_playlist_coordinator.dart';
import 'package:vsasr_app/src/video/video_playlist_store.dart';

void main() {
  test('协调器管理播放列表状态并在销毁后解绑监听器', () async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'vsasr_playlist_coordinator_test',
    );
    final _FakeVideoBackend backend = _FakeVideoBackend();
    final VideoPlaybackController player = VideoPlaybackController(
      backend: backend,
    );
    final TranscribeController transcription = TranscribeController();
    final VideoPlaylistCoordinator coordinator = VideoPlaylistCoordinator(
      controller: player,
      transcription: transcription,
      playlistStore: VideoPlaylistStore(rootDirectory: workspace),
    );
    addTearDown(() async {
      coordinator.dispose();
      player.dispose();
      await transcription.shutdown();
      workspace.deleteSync(recursive: true);
    });

    coordinator.init();
    coordinator.setProcessingPreferences(
      translationEnabled: false,
      cacheEnabled: false,
    );
    const TranscriptionResult result = TranscriptionResult(
      segments: <Segment>[Segment(text: '第一句', start: 0, end: 1, index: 0)],
      duration: 1,
      language: 'zh',
    );
    coordinator.storePlaylistResult('/tmp/first.mp4', result);
    coordinator.storePlaylistResult('/tmp/second.mp4', result);

    await coordinator.replaceWith('/tmp/first.mp4', result: result);
    await coordinator.addPaths(<String>['/tmp/second.mp4']);
    expect(coordinator.playlist, <String>['/tmp/first.mp4', '/tmp/second.mp4']);

    coordinator.reorderPlaylist(0, 1);
    expect(coordinator.playlist, <String>['/tmp/second.mp4', '/tmp/first.mp4']);
    expect(coordinator.currentPlaylistIndex, 1);

    await coordinator.removePlaylistItem(1);
    expect(coordinator.playlist, <String>['/tmp/second.mp4']);
    expect(player.filePath, '/tmp/second.mp4');

    int notifications = 0;
    coordinator.addListener(() => notifications++);
    coordinator.dispose();
    backend.emitDuration(const Duration(seconds: 10));
    expect(notifications, 0);
  });
}

class _FakeVideoBackend implements VideoPlayerBackend {
  final StreamController<Duration> _durations =
      StreamController<Duration>.broadcast(sync: true);

  @override
  Widget buildVideo({VideoOverlayBuilder? overlayBuilder}) =>
      const SizedBox.expand();

  @override
  Stream<Duration> get position => const Stream<Duration>.empty();

  @override
  Stream<Duration> get duration => _durations.stream;

  @override
  Stream<bool> get playing => const Stream<bool>.empty();

  @override
  Future<void> open(String path) async {}

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> dispose() async => _durations.close();

  void emitDuration(Duration value) => _durations.add(value);
}
