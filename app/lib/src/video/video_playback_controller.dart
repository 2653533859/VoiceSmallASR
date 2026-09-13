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

class VideoSubtitleTrackInfo {
  const VideoSubtitleTrackInfo({required this.id, this.title, this.language});

  final String id;
  final String? title;
  final String? language;
}

/// 原生播放器可选实现，用于枚举和选择视频内嵌字幕轨。
abstract interface class EmbeddedSubtitleTrackBackend {
  Stream<List<VideoSubtitleTrackInfo>> get embeddedSubtitleTracks;

  Future<void> selectEmbeddedSubtitleTrack(String? id);
}

/// 基于 media_kit 的 Android / macOS / Windows 播放器后端。
class MediaKitVideoPlayerBackend
    implements VideoPlayerBackend, EmbeddedSubtitleTrackBackend {
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
  Stream<List<VideoSubtitleTrackInfo>> get embeddedSubtitleTracks =>
      _player.stream.tracks.map(
        (tracks) => tracks.subtitle
            .where((track) => track.id != 'auto' && track.id != 'no')
            .map(
              (track) => VideoSubtitleTrackInfo(
                id: track.id,
                title: track.title,
                language: track.language,
              ),
            )
            .toList(growable: false),
      );

  @override
  Future<void> open(String path) async {
    await _player.open(Media(Uri.file(path).toString()), play: false);
    await _player.setSubtitleTrack(SubtitleTrack.no());
  }

  @override
  Future<void> selectEmbeddedSubtitleTrack(String? id) async {
    if (id == null) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    final track = _player.state.tracks.subtitle
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (track == null) throw StateError('内嵌字幕轨已不可用');
    await _player.setSubtitleTrack(track);
  }

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
    if (_backend is EmbeddedSubtitleTrackBackend) {
      final trackBackend = _backend as EmbeddedSubtitleTrackBackend;
      _subscriptions.add(
        trackBackend.embeddedSubtitleTracks.listen(_onEmbeddedSubtitleTracks),
      );
    }
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
  List<VideoSubtitleTrackInfo> _embeddedSubtitleTracks = const [];
  String? _selectedEmbeddedSubtitleTrackId;
  Duration _lastPublishedPosition = Duration.zero;
  Duration _backendPosition = Duration.zero;
  Duration? _queuedSeek;
  Duration? _seekTarget;
  Future<void>? _seekOperation;
  Timer? _seekSettlement;
  int _mediaGeneration = 0;

  static const Duration _positionPublishInterval = Duration(milliseconds: 200);
  static const Duration _playbackEndNotificationWindow = Duration(
    milliseconds: 250,
  );

  String? get filePath => _filePath;

  Duration get position => _position;

  /// 后端报告的实际位置，不能用尚未确认的跳转目标判断播放结束。
  Duration get actualPosition => _backendPosition;

  bool get seeking => _seekOperation != null || _seekTarget != null;

  Duration get duration => _duration;

  bool get playing => _playing;

  double get rate => _rate;

  bool get busy => _busy;

  String? get errorText => _errorText;

  List<VideoSubtitleTrackInfo> get embeddedSubtitleTracks =>
      List.unmodifiable(_embeddedSubtitleTracks);

  String? get selectedEmbeddedSubtitleTrackId =>
      _selectedEmbeddedSubtitleTrackId;

  Widget buildVideo({VideoOverlayBuilder? overlayBuilder}) =>
      _backend.buildVideo(overlayBuilder: overlayBuilder);

  Future<void> open(String path) async {
    if (_disposed || _busy) return;
    _busy = true;
    _mediaGeneration++;
    _queuedSeek = null;
    _seekTarget = null;
    _seekSettlement?.cancel();
    _backendPosition = Duration.zero;
    _errorText = null;
    _filePath = path;
    _position = Duration.zero;
    _lastPublishedPosition = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _embeddedSubtitleTracks = const [];
    _selectedEmbeddedSubtitleTrackId = null;
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

  /// 仅在正在播放时暂停，供页面切换和启动重任务前释放播放器资源。
  Future<void> pause() async {
    if (_disposed || _filePath == null || _busy || !_playing) return;
    try {
      await _backend.playOrPause();
    } on Object catch (error) {
      if (_disposed) return;
      _errorText = '暂停失败：$error';
      notifyListeners();
    }
  }

  Future<void> seek(Duration target) {
    if (_disposed || _filePath == null || _busy) return Future<void>.value();
    final Duration clamped = _clampPosition(target);
    _seekSettlement?.cancel();
    _seekTarget = clamped;
    _queuedSeek = clamped;
    // 立即发布目标，让连按基于新位置累加，而非重复使用滞后的原生位置。
    _position = clamped;
    _lastPublishedPosition = clamped;
    _errorText = null;
    // 先占用执行槽，再通知监听者，避免字幕循环等回调重入启动第二路 seek。
    final Future<void> operation;
    if (_seekOperation == null) {
      final completion = Completer<void>();
      operation = completion.future;
      _seekOperation = operation;
      unawaited(_drainSeeks(completion));
    } else {
      operation = _seekOperation!;
    }
    notifyListeners();
    return operation;
  }

  Future<void> _drainSeeks(Completer<void> completion) async {
    try {
      while (!_disposed && _queuedSeek != null) {
        final target = _queuedSeek!;
        final generation = _mediaGeneration;
        _queuedSeek = null;
        try {
          await _backend.seek(target);
          if (_disposed || generation != _mediaGeneration) continue;
          if (_queuedSeek == null && _seekTarget != null) {
            // 部分后端先完成命令、后报告位置；短暂屏蔽旧位置，超时恢复真实位置。
            _seekSettlement = Timer(const Duration(seconds: 1), () {
              if (_disposed || generation != _mediaGeneration) return;
              _seekTarget = null;
              _onPosition(_backendPosition);
            });
          }
        } on Object catch (error) {
          if (_disposed || generation != _mediaGeneration) continue;
          if (_queuedSeek == null) {
            _seekTarget = null;
            _position = _backendPosition;
            _lastPublishedPosition = _position;
            _errorText = '跳转失败：$error';
            notifyListeners();
          }
        }
      }
    } finally {
      _seekOperation = null;
      completion.complete();
      if (!_disposed) notifyListeners();
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

  Future<void> selectEmbeddedSubtitleTrack(String? id) async {
    if (_disposed || _filePath == null || _busy) return;
    if (_backend is! EmbeddedSubtitleTrackBackend) return;
    final trackBackend = _backend as EmbeddedSubtitleTrackBackend;
    try {
      await trackBackend.selectEmbeddedSubtitleTrack(id);
      if (_disposed) return;
      _selectedEmbeddedSubtitleTrackId = id;
      _errorText = null;
      notifyListeners();
    } on Object catch (error) {
      if (_disposed) return;
      _errorText = '选择内嵌字幕失败：$error';
      notifyListeners();
    }
  }

  void _onEmbeddedSubtitleTracks(List<VideoSubtitleTrackInfo> tracks) {
    if (_disposed) return;
    _embeddedSubtitleTracks = List.unmodifiable(tracks);
    if (_selectedEmbeddedSubtitleTrackId != null &&
        !tracks.any((track) => track.id == _selectedEmbeddedSubtitleTrackId)) {
      _selectedEmbeddedSubtitleTrackId = null;
    }
    notifyListeners();
  }

  Duration _clampPosition(Duration target) {
    if (target.isNegative) return Duration.zero;
    if (_duration > Duration.zero && target > _duration) return _duration;
    return target;
  }

  void _onPosition(Duration value) {
    if (_disposed) return;
    final Duration next = _clampPosition(value);
    _backendPosition = next;
    final target = _seekTarget;
    if (target != null) {
      if ((next - target).abs() > const Duration(milliseconds: 500)) return;
      _seekTarget = null;
      _seekSettlement?.cancel();
    }
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
    _queuedSeek = null;
    _seekSettlement?.cancel();
    for (final StreamSubscription<dynamic> subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_backend.dispose());
    super.dispose();
  }
}
