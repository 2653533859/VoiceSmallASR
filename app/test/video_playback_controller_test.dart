import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_timeline.dart';
import 'package:vsasr_app/src/asr/segment.dart';

void main() {
  test('播放控制器同步状态、播放暂停和带边界的跳转', () async {
    final _FakeVideoBackend backend = _FakeVideoBackend();
    final VideoPlaybackController controller = VideoPlaybackController(backend: backend);
    addTearDown(controller.dispose);

    await controller.open('/tmp/movie.mp4');
    expect(controller.filePath, '/tmp/movie.mp4');

    backend.emitDuration(const Duration(seconds: 10));
    backend.emitPosition(const Duration(seconds: 4));
    backend.emitPlaying(true);
    expect(controller.duration, const Duration(seconds: 10));
    expect(controller.position, const Duration(seconds: 4));
    expect(controller.playing, isTrue);

    await controller.playOrPause();
    expect(backend.playOrPauseCalls, 1);
    await controller.seek(const Duration(seconds: 99));
    expect(backend.lastSeek, const Duration(seconds: 10));
  });

  test('字幕时间轴在段首包含、段尾切换', () {
    const List<Segment> segments = <Segment>[
      Segment(text: '第一句', start: 0, end: 1, index: 0),
      Segment(text: '第二句', start: 1, end: 2, index: 1),
    ];

    expect(activeSegment(segments, const Duration(milliseconds: 500))?.text, '第一句');
    expect(activeSegment(segments, const Duration(seconds: 1))?.text, '第二句');
    expect(activeSegment(segments, const Duration(seconds: 2)), isNull);
  });

  test('关闭期间打开操作完成后不访问已销毁的控制器', () async {
    final _FakeVideoBackend backend = _FakeVideoBackend()..pendingOpen = Completer<void>();
    final VideoPlaybackController controller = VideoPlaybackController(backend: backend);
    final Future<void> opening = controller.open('/tmp/movie.mp4');
    controller.dispose();
    backend.pendingOpen!.complete();
    await opening;
  });
}

class _FakeVideoBackend implements VideoPlayerBackend {
  final StreamController<Duration> _positions = StreamController<Duration>.broadcast(sync: true);
  final StreamController<Duration> _durations = StreamController<Duration>.broadcast(sync: true);
  final StreamController<bool> _playing = StreamController<bool>.broadcast(sync: true);

  String? openedPath;
  Duration? lastSeek;
  int playOrPauseCalls = 0;
  Completer<void>? pendingOpen;

  @override
  Widget buildVideo() => const SizedBox();

  @override
  Stream<Duration> get position => _positions.stream;

  @override
  Stream<Duration> get duration => _durations.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Future<void> open(String path) async {
    openedPath = path;
    final Completer<void>? pending = pendingOpen;
    if (pending != null) await pending.future;
  }

  @override
  Future<void> playOrPause() async => playOrPauseCalls++;

  @override
  Future<void> seek(Duration position) async => lastSeek = position;

  @override
  Future<void> dispose() async {
    await Future.wait<void>(<Future<void>>[
      _positions.close(),
      _durations.close(),
      _playing.close(),
    ]);
  }

  void emitPosition(Duration value) => _positions.add(value);

  void emitDuration(Duration value) => _durations.add(value);

  void emitPlaying(bool value) => _playing.add(value);
}
