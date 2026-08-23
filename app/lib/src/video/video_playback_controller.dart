/// 跨平台视频播放控制器。
///
/// 播放器实现藏在 [VideoPlayerBackend] 后面，界面只依赖播放状态、控制方法与
/// 一个渲染 Widget。这样时间轴和字幕联动可以在不加载原生播放器的测试里验证。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' as media_kit_video;

typedef VideoOverlayBuilder = Widget Function(
  Future<void> Function() toggleFullscreen,
);

/// 播放器后端，供真实平台实现与测试替身共用。
abstract interface class VideoPlayerBackend {
  Widget buildVideo({VideoOverlayBuilder? overlayBuilder});

  Stream<Duration> get position;

  Stream<Duration> get duration;

  Stream<bool> get playing;

  Future<void> open(String path);

  Future<void> playOrPause();

  Future<void> seek(Duration position);

  Future<void> setRate(double rate);

  Future<void> dispose();
}

/// 基于 media_kit 的 Android / macOS / Windows 播放器后端。
class MediaKitVideoPlayerBackend implements VideoPlayerBackend {
  MediaKitVideoPlayerBackend() {
    _videoController = media_kit_video.VideoController(_player);
  }

  final Player _player = Player();
  late final media_kit_video.VideoController _videoController;

  @override
  Widget buildVideo({VideoOverlayBuilder? overlayBuilder}) =>
      media_kit_video.Video(
        controller: _videoController,
        controls: overlayBuilder == null
            ? media_kit_video.NoVideoControls
            : (media_kit_video.VideoState state) =>
                  overlayBuilder(state.toggleFullscreen),
      );

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  Future<void> open(String path) =>
      _player.open(Media(Uri.file(path).toString()), play: false);

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> dispose() => _player.dispose();
}

/// 播放器的 UI 状态与控制入口。
class VideoPlaybackController extends ChangeNotifier {
  VideoPlaybackController({VideoPlayerBackend? backend})
    : _backend = backend ?? MediaKitVideoPlayerBackend() {
    _subscriptions = <StreamSubscription<dynamic>>[
      _backend.position.listen(_onPosition),
      _backend.duration.listen(_onDuration),
      _backend.playing.listen(_onPlaying),
    ];
  }

  final VideoPlayerBackend _backend;
  late final List<StreamSubscription<dynamic>> _subscriptions;

  String? _filePath;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  double _rate = 1.0;
  bool _busy = false;
  String? _errorText;
  bool _disposed = false;
  Duration _lastPublishedPosition = Duration.zero;

  static const Duration _positionPublishInterval = Duration(milliseconds: 200);
  static const Duration _playbackEndNotificationWindow = Duration(
    milliseconds: 250,
  );

  String? get filePath => _filePath;

  Duration get position => _position;

  Duration get duration => _duration;

  bool get playing => _playing;

  double get rate => _rate;

  bool get busy => _busy;

  String? get errorText => _errorText;

  Widget buildVideo({VideoOverlayBuilder? overlayBuilder}) =>
      _backend.buildVideo(overlayBuilder: overlayBuilder);

  Future<void> open(String path) async {
    if (_disposed || _busy) return;
    _busy = true;
    _errorText = null;
    _filePath = path;
    _position = Duration.zero;
    _lastPublishedPosition = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    notifyListeners();
    try {
      await _backend.open(path);
    } on Object catch (error) {
      if (_disposed) return;
      _filePath = null;
      _errorText = '打开视频失败：$error';
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> playOrPause() async {
    if (_disposed || _filePath == null || _busy) return;
    try {
      await _backend.playOrPause();
    } on Object catch (error) {
      if (_disposed) return;
      _errorText = '播放失败：$error';
      notifyListeners();
    }
  }

  Future<void> seek(Duration target) async {
    if (_disposed || _filePath == null || _busy) return;
    final Duration clamped = _clampPosition(target);
    try {
      await _backend.seek(clamped);
    } on Object catch (error) {
      if (_disposed) return;
      _errorText = '跳转失败：$error';
      notifyListeners();
    }
  }

  Future<void> setRate(double value) async {
    if (_disposed || _filePath == null || _busy || value <= 0) return;
    try {
      await _backend.setRate(value);
      if (_disposed) return;
      _rate = value;
      notifyListeners();
    } on Object catch (error) {
      if (_disposed) return;
      _errorText = '调整倍速失败：$error';
      notifyListeners();
    }
  }

  Duration _clampPosition(Duration target) {
    if (target.isNegative) return Duration.zero;
    if (_duration > Duration.zero && target > _duration) return _duration;
    return target;
  }

  void _onPosition(Duration value) {
    if (_disposed) return;
    final Duration next = _clampPosition(value);
    _position = next;
    final Duration delta = next - _lastPublishedPosition;
    final Duration endWindowStart = _duration > _playbackEndNotificationWindow
        ? _duration - _playbackEndNotificationWindow
        : Duration.zero;
    final bool enteredEndWindow =
        _duration > Duration.zero &&
        next >= endWindowStart &&
        _lastPublishedPosition < endWindowStart;
    if (next > Duration.zero &&
        next != _duration &&
        !enteredEndWindow &&
        !delta.isNegative &&
        delta < _positionPublishInterval) {
      return;
    }
    _lastPublishedPosition = next;
    notifyListeners();
  }

  void _onDuration(Duration value) {
    if (_disposed) return;
    _duration = value.isNegative ? Duration.zero : value;
    _position = _clampPosition(_position);
    notifyListeners();
  }

  void _onPlaying(bool value) {
    if (_disposed) return;
    _playing = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final StreamSubscription<dynamic> subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_backend.dispose());
    super.dispose();
  }
}
