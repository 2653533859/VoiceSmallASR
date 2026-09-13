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

  test('默认仅播放，不读取同名字幕；手动开启后加载，关闭时禁用翻译', () async {
    final root = Directory.systemTemp.createTempSync('manual_subtitle_');
    final media = File('${root.path}/movie.mp4')..createSync();
    final missing = File('${root.path}/missing.mp4')..createSync();
    File('${root.path}/movie.srt')
        .writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n手动加载\n');
    final transcription = TranscribeController();
    final player = VideoPlaybackController(backend: _FakeVideoBackend());
    final coordinator = VideoPlaylistCoordinator(
      controller: player,
      transcription: transcription,
      subtitleCache: VideoSubtitleCache(rootDirectory: root),
      playlistStore: VideoPlaylistStore(rootDirectory: root),
    );
    addTearDown(() async {
      coordinator.dispose();
      player.dispose();
      await transcription.shutdown();
      root.deleteSync(recursive: true);
    });
    await coordinator.addPaths([media.path, missing.path]);
    coordinator.setTranslationEnabled(true);
    expect(coordinator.subtitlesEnabled, isFalse);
    expect(coordinator.translationEnabled, isFalse);
    expect(coordinator.resultFor(media.path), isNull);
    expect(transcription.busy, isFalse);
    coordinator.setSubtitleLoadMode(VideoSubtitleLoadMode.existingOnly);
    await _waitUntil(
      () => coordinator.playlistStatus[media.path] == '同名 SRT · 已缓存',
    );
    await _waitUntil(
      () => coordinator.playlistStatus[missing.path] == '未找到已有字幕',
    );
    expect(coordinator.resultFor(media.path)?.segments.single.text, '手动加载');
    expect(coordinator.resultFor(missing.path), isNull);
    expect(transcription.busy, isFalse);
    coordinator.setSubtitleLoadMode(VideoSubtitleLoadMode.off);
    expect(coordinator.translationEnabled, isFalse);
    expect(coordinator.playlistStatus[media.path], '未加载字幕');
  });

  test('识别中切换到仅加载已有不会把增量结果当作完整字幕', () async {
    final root = Directory.systemTemp.createTempSync('switch_subtitle_mode_');
    final media = File('${root.path}/movie.mp4')..createSync();
    final decoder = _InterruptibleDecoder();
    final transcription = TranscribeController(
      decoder: decoder,
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async => FakeTranscriber(
            language: 'ja',
            liveSegments: const <Segment>[
              Segment(
                text: '途中の字幕',
                start: 0,
                end: 1,
                index: 0,
                language: 'ja',
              ),
            ],
          ),
    );
    final player = VideoPlaybackController(backend: _FakeVideoBackend());
    final coordinator = VideoPlaylistCoordinator(
      subtitleLoadMode: VideoSubtitleLoadMode.recognizeMissing,
      controller: player,
      transcription: transcription,
      subtitleCache: VideoSubtitleCache(rootDirectory: root),
      playlistStore: VideoPlaylistStore(rootDirectory: root),
    );
    addTearDown(() async {
      coordinator.dispose();
      player.dispose();
      await transcription.shutdown();
      root.deleteSync(recursive: true);
    });
    coordinator.setProcessingPreferences(
      translationEnabled: false,
      cacheEnabled: false,
    );
    await coordinator.replaceWith(media.path);
    await decoder.firstChunkYielded.future;
    await _waitUntil(() => coordinator.resultFor(media.path) != null);

    coordinator.setSubtitleLoadMode(VideoSubtitleLoadMode.existingOnly);
    decoder.allowFirstFinish.complete();
    await _waitUntil(
      () => coordinator.playlistStatus[media.path] == '未找到已有字幕',
    );
    expect(coordinator.resultFor(media.path), isNull);

    coordinator.setSubtitleLoadMode(VideoSubtitleLoadMode.recognizeMissing);
    await _waitUntil(
      () => coordinator.playlistStatus[media.path] == '自动识别 · 已就绪',
    );
    expect(decoder.calls, 2);
    expect(coordinator.resultFor(media.path)?.segments.single.text, '途中の字幕');
  });

  for (final cacheEnabled in [false, true]) {
    test('同名 SRT 优先于缓存且不启动识别，缓存开关 $cacheEnabled', () async {
      final root = Directory.systemTemp.createTempSync('playlist_srt_');
      final media = File('${root.path}/movie.mp4')..createSync();
      File('${root.path}/movie.SRT')
          .writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n外部字幕\n');
      int launches = 0;
      final transcription = TranscribeController(
        launch:
            ({
              required AsrConfig config,
              required bool allowDownload,
              required ModelProgress onModelProgress,
            }) async {
              launches++;
              throw StateError('不应识别');
            },
      );
      final player = VideoPlaybackController(backend: _FakeVideoBackend());
      final cache = VideoSubtitleCache(rootDirectory: root);
      final coordinator = VideoPlaylistCoordinator(
        subtitleLoadMode: VideoSubtitleLoadMode.recognizeMissing,
        controller: player,
        transcription: transcription,
        subtitleCache: cache,
        playlistStore: VideoPlaylistStore(rootDirectory: root),
      );
      await cache.write(
        media.path,
        const TranscriptionResult(
          segments: [Segment(text: '旧缓存', start: 0, end: 1)],
        ),
        configurationScope: coordinator.videoSubtitleCacheScope(
          const TranslationApiSettings(),
        ),
      );
      addTearDown(() async {
        coordinator.dispose();
        player.dispose();
        await transcription.shutdown();
        root.deleteSync(recursive: true);
      });
      coordinator.setProcessingPreferences(
        translationEnabled: false,
        cacheEnabled: cacheEnabled,
      );
      await coordinator.replaceWith(media.path);
      await _waitUntil(
        () =>
            coordinator.playlistStatus[media.path] ==
            (cacheEnabled ? '同名 SRT · 已缓存' : '同名 SRT · 已就绪'),
      );
      expect(coordinator.resultFor(media.path)?.segments.single.text, '外部字幕');
      expect(launches, 0);
      expect(
        File('${root.path}/movie.SRT').readAsStringSync(),
        contains('外部字幕'),
      );
    });
  }

  test('按优先级加载语言后缀 ASS 配套字幕且不启动识别', () async {
    final root = Directory.systemTemp.createTempSync('playlist_ass_');
    final media = File('${root.path}/movie.mp4')..createSync();
    File('${root.path}/movie.ja.ass').writeAsStringSync('''[Script Info]
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,日本語字幕
''');
    var launches = 0;
    final transcription = TranscribeController(
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            launches++;
            throw StateError('不应识别');
          },
    );
    final player = VideoPlaybackController(backend: _FakeVideoBackend());
    final coordinator = VideoPlaylistCoordinator(
      subtitleLoadMode: VideoSubtitleLoadMode.existingOnly,
      controller: player,
      transcription: transcription,
      subtitleCache: VideoSubtitleCache(rootDirectory: root),
      playlistStore: VideoPlaylistStore(rootDirectory: root),
    );
    addTearDown(() async {
      coordinator.dispose();
      player.dispose();
      await transcription.shutdown();
      root.deleteSync(recursive: true);
    });
    await coordinator.addPaths(<String>[media.path]);
    await _waitUntil(
      () => coordinator.playlistStatus[media.path] == '语言后缀 ASS · 已缓存',
    );
    expect(coordinator.resultFor(media.path)?.text, '日本語字幕');
    expect(launches, 0);
  });

  test('无效同名 SRT 提示错误、不识别，继续处理下一项', () async {
    final root = Directory.systemTemp.createTempSync('playlist_bad_srt_');
    final first = File('${root.path}/1.mp4')..createSync();
    final second = File('${root.path}/2.mp4')..createSync();
    File('${root.path}/1.srt').writeAsStringSync('invalid');
    File('${root.path}/2.srt')
        .writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n第二个字幕\n');
    int launches = 0;
    final transcription = TranscribeController(
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            launches++;
            throw StateError('不应识别');
          },
    );
    final player = VideoPlaybackController(backend: _FakeVideoBackend());
    final coordinator = VideoPlaylistCoordinator(
      subtitleLoadMode: VideoSubtitleLoadMode.recognizeMissing,
      controller: player,
      transcription: transcription,
      subtitleCache: VideoSubtitleCache(rootDirectory: root),
      playlistStore: VideoPlaylistStore(rootDirectory: root),
    );
    addTearDown(() async {
      coordinator.dispose();
      player.dispose();
      await transcription.shutdown();
      root.deleteSync(recursive: true);
    });
    await coordinator.addPaths([first.path, second.path]);
    await _waitUntil(
      () => coordinator.playlistStatus[second.path] == '同名 SRT · 已缓存',
    );
    expect(coordinator.playlistStatus[first.path], startsWith('同名 SRT 加载失败'));
    expect(coordinator.resultFor(second.path)?.segments.single.text, '第二个字幕');
    expect(launches, 0);
  });

  test('未确认和失败的片尾跳转不会自动切换，实际到达片尾才切换', () async {
    final root = Directory.systemTemp.createTempSync('seek_playlist_');
    final backend = _FakeVideoBackend();
    final player = VideoPlaybackController(backend: backend);
    final transcription = TranscribeController();
    final coordinator = VideoPlaylistCoordinator(
      subtitleLoadMode: VideoSubtitleLoadMode.recognizeMissing,
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
      subtitleLoadMode: VideoSubtitleLoadMode.recognizeMissing,
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
      subtitleLoadMode: VideoSubtitleLoadMode.recognizeMissing,
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
    await _waitUntil(
      () => coordinator.playlistStatus[media.path] == '自动识别 · 已缓存',
    );
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
      subtitleLoadMode: VideoSubtitleLoadMode.recognizeMissing,
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
    await _waitUntil(
      () => coordinator.playlistStatus[second.path] == '自动识别 · 已缓存',
    );
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

class _InterruptibleDecoder implements AudioDecoder, ChunkedAudioDecoder {
  final Completer<void> firstChunkYielded = Completer<void>();
  final Completer<void> allowFirstFinish = Completer<void>();
  int calls = 0;

  @override
  Future<Float32List> decodeFile(String path) async => Float32List(kSampleRate);

  @override
  Stream<DecodedAudioChunk> decodeFileChunks(
    String path, {
    Duration chunkDuration = const Duration(seconds: 10),
  }) async* {
    calls++;
    final call = calls;
    yield DecodedAudioChunk(Float32List(kSampleRate), isLast: call != 1);
    if (call == 1) {
      firstChunkYielded.complete();
      await allowFirstFinish.future;
      yield DecodedAudioChunk(Float32List(kSampleRate), isLast: true);
    }
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
