import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_playlist_coordinator.dart';
import 'package:vsasr_app/src/video/video_playlist_store.dart';
import 'package:vsasr_app/src/video/video_subtitle_cache.dart';

import 'support/fake_asr.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未确认和失败的片尾跳转不会自动切换，实际到达片尾才切换', () async {
    final root = Directory.systemTemp.createTempSync('seek_playlist_');
    final backend = _FakeVideoBackend();
    final player = VideoPlaybackController(backend: backend);
    final transcription = TranscribeController();
    final coordinator = VideoPlaylistCoordinator(
      controller: player,
      transcription: transcription,
      playlistStore: VideoPlaylistStore(rootDirectory: root),
    );
    addTearDown(() async {
      coordinator.dispose();
      player.dispose();
      await transcription.shutdown();
      root.deleteSync(recursive: true);
    });
    coordinator.init();
    coordinator.setProcessingPreferences(
      translationEnabled: false,
      cacheEnabled: false,
    );
    const result = TranscriptionResult(segments: [], duration: 30);
    coordinator.storePlaylistResult('/tmp/b.mp4', result);
    await coordinator.replaceWith('/tmp/a.mp4', result: result);
    await coordinator.addPaths(['/tmp/b.mp4']);
    backend.emitDuration(const Duration(seconds: 30));
    backend.positions.add(const Duration(seconds: 20));
    backend.pendingSeek = Completer<void>();
    backend.failSeek = true;
    final seeking = player.seek(const Duration(seconds: 30));
    expect(player.position, const Duration(seconds: 30));
    expect(player.actualPosition, const Duration(seconds: 20));
    expect(coordinator.currentPlaylistIndex, 0);
    backend.pendingSeek!.complete();
    await seeking;
    expect(coordinator.currentPlaylistIndex, 0);
    expect(player.filePath, '/tmp/a.mp4');
    backend.failSeek = false;
    backend.pendingSeek = null;
    await player.seek(const Duration(seconds: 30));
    expect(coordinator.currentPlaylistIndex, 0);
    backend.positions.add(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.currentPlaylistIndex, 1);
    expect(player.filePath, '/tmp/b.mp4');
  });

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

  test('应用暂停时保存短片段检查点，唤醒后继续播放列表转写', () async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'vsasr_playlist_lifecycle_test',
    );
    final File media = File('${workspace.path}/sample.mp4')
      ..writeAsBytesSync(<int>[0]);
    final _LifecycleDecoder decoder = _LifecycleDecoder();
    final FakeTranscriber worker = FakeTranscriber(
      language: 'en',
      liveSegments: const <Segment>[
        Segment(text: 'short clip', start: 0, end: 1, index: 0, language: 'en'),
      ],
    );
    final TranscribeController transcription = TranscribeController(
      decoder: decoder,
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => worker,
    );
    final VideoPlaybackController player = VideoPlaybackController(
      backend: _FakeVideoBackend(),
    );
    final VideoSubtitleCache cache = VideoSubtitleCache(
      rootDirectory: Directory('${workspace.path}/cache'),
    );
    final VideoPlaylistCoordinator coordinator = VideoPlaylistCoordinator(
      controller: player,
      transcription: transcription,
      subtitleCache: cache,
      playlistStore: VideoPlaylistStore(rootDirectory: workspace),
    );
    addTearDown(() async {
      coordinator.dispose();
      player.dispose();
      await transcription.shutdown();
      workspace.deleteSync(recursive: true);
    });

    coordinator.init();
    await coordinator.replaceWith(media.path);
    await decoder.firstChunkYielded.future;

    coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
    decoder.allowNextChunk.complete();
    await _waitUntil(
      () => coordinator.playlistStatus[media.path]?.contains('检查点已保存') == true,
    );

    final VideoSubtitleCheckpoint? checkpoint = await cache.readCheckpoint(
      media.path,
      configurationScope: coordinator.videoSubtitleCacheScope(
        const TranslationApiSettings(),
      ),
    );
    expect(checkpoint, isNotNull);
    expect(checkpoint!.processedSamples, kSampleRate);
    expect(coordinator.lifecycleSuspended, isTrue);

    coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await _waitUntil(() => coordinator.playlistStatus[media.path] == '字幕已缓存');
    expect(coordinator.lifecycleSuspended, isFalse);
  });

  test('一个播放列表条目解码失败后，后续条目仍会完成并缓存', () async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'vsasr_playlist_continue_after_failure_test',
    );
    final File first = File('${workspace.path}/broken.mp4')
      ..writeAsBytesSync(<int>[0]);
    final File second = File('${workspace.path}/next.mp4')
      ..writeAsBytesSync(<int>[0]);
    final _FailFirstDecoder decoder = _FailFirstDecoder(first.path);
    final TranscribeController transcription = TranscribeController(
      decoder: decoder,
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async => FakeTranscriber(
            language: 'en',
            liveSegments: const <Segment>[
              Segment(text: 'next item', start: 0, end: 1, index: 0),
            ],
          ),
    );
    final VideoPlaybackController player = VideoPlaybackController(
      backend: _FakeVideoBackend(),
    );
    final VideoPlaylistCoordinator coordinator = VideoPlaylistCoordinator(
      controller: player,
      transcription: transcription,
      subtitleCache: VideoSubtitleCache(
        rootDirectory: Directory('${workspace.path}/cache'),
      ),
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
      cacheEnabled: true,
    );
    await coordinator.replaceWith(first.path);
    await decoder.firstStarted.future;
    await coordinator.addPaths(<String>[second.path]);
    decoder.failFirst.complete();

    await _waitUntil(
      () => coordinator.playlistStatus[first.path]?.startsWith('转写失败：') == true,
    );
    await _waitUntil(() => coordinator.playlistStatus[second.path] == '字幕已缓存');
    expect(coordinator.resultFor(first.path), isNull);
    expect(
      coordinator.resultFor(second.path)?.segments.single.text,
      'next item',
    );
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (int index = 0; index < 100; index++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待异步状态超时');
}

class _LifecycleDecoder implements AudioDecoder, ChunkedAudioDecoder {
  final Completer<void> firstChunkYielded = Completer<void>();
  final Completer<void> allowNextChunk = Completer<void>();

  @override
  Future<Float32List> decodeFile(String path) async => Float32List(kSampleRate);

  @override
  Stream<DecodedAudioChunk> decodeFileChunks(
    String path, {
    Duration chunkDuration = const Duration(seconds: 10),
  }) async* {
    if (!firstChunkYielded.isCompleted) {
      firstChunkYielded.complete();
      yield DecodedAudioChunk(Float32List(kSampleRate), isLast: false);
      await allowNextChunk.future;
    }
    yield DecodedAudioChunk(Float32List(kSampleRate), isLast: true);
  }
}

class _FailFirstDecoder implements AudioDecoder, ChunkedAudioDecoder {
  _FailFirstDecoder(this.firstPath);

  final String firstPath;
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> failFirst = Completer<void>();

  @override
  Future<Float32List> decodeFile(String path) async => Float32List(kSampleRate);

  @override
  Stream<DecodedAudioChunk> decodeFileChunks(
    String path, {
    Duration chunkDuration = const Duration(seconds: 10),
  }) async* {
    if (path == firstPath) {
      firstStarted.complete();
      await failFirst.future;
      throw const AudioDecodeException('模拟解码器异常');
    }
    yield DecodedAudioChunk(Float32List(kSampleRate), isLast: true);
  }
}

class _FakeVideoBackend implements VideoPlayerBackend {
  final positions = StreamController<Duration>.broadcast(sync: true);
  Completer<void>? pendingSeek;
  bool failSeek = false;
  final StreamController<Duration> _durations =
      StreamController<Duration>.broadcast(sync: true);

  @override
  Widget buildVideo({VideoOverlayBuilder? overlayBuilder}) =>
      const SizedBox.expand();

  @override
  Stream<Duration> get position => positions.stream;

  @override
  Stream<Duration> get duration => _durations.stream;

  @override
  Stream<bool> get playing => const Stream<bool>.empty();

  @override
  Future<void> open(String path) async {}

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> seek(Duration position) async {
    if (pendingSeek != null) await pendingSeek!.future;
    if (failSeek) throw StateError('seek failed');
  }

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> dispose() async {
    await _durations.close();
    await positions.close();
  }

  void emitDuration(Duration value) => _durations.add(value);
}
