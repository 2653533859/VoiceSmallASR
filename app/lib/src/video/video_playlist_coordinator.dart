/// 视频播放列表、流式转写与字幕缓存的业务协调器。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/ui/transcription_task_scheduler.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_playlist_store.dart';
import 'package:vsasr_app/src/video/video_subtitle_cache.dart';

typedef RequestTranslationDisclosure = Future<bool> Function();
typedef TranslationPreferenceChanged = Future<void> Function(bool enabled);

class VideoPlaylistCoordinator extends ChangeNotifier
    with WidgetsBindingObserver {
  VideoPlaylistCoordinator({
    required this.controller,
    required this.transcription,
    this.settings,
    this.translationProviderResolver,
    VideoSubtitleCache? subtitleCache,
    VideoPlaylistStore? playlistStore,
    this.requestTranslationDisclosure,
    this.onTranslationPreferenceChanged,
  }) : _subtitleCache = subtitleCache ?? const VideoSubtitleCache(),
       _playlistStore = playlistStore ?? VideoPlaylistStore();

  final VideoPlaybackController controller;
  final TranscribeController transcription;
  final AppSettingsRepository? settings;
  final Future<TranslationProvider?> Function()? translationProviderResolver;
  final RequestTranslationDisclosure? requestTranslationDisclosure;
  final TranslationPreferenceChanged? onTranslationPreferenceChanged;
  final VideoSubtitleCache _subtitleCache;
  final VideoPlaylistStore _playlistStore;

  final List<String> _playlist = <String>[];
  final Map<String, TranscriptionResult> _playlistResults =
      <String, TranscriptionResult>{};
  final Set<String> _partialPlaylistResults = <String>{};
  final Set<String> _cancelledPlaylistPaths = <String>{};
  final Set<String> _cacheWritePaths = <String>{};
  final Map<String, String> _playlistStatus = <String, String>{};
  final Map<String, String> _translationWarnings = <String, String>{};
  int _currentPlaylistIndex = -1;
  int _playlistGeneration = 0;
  bool _processingRequested = false;
  bool _waitingForTranscription = false;
  Future<void>? _processingFuture;
  Future<void> _translationQueue = Future<void>.value();
  bool _autoAdvancing = false;
  String? _cacheDirectory;
  String? _processingPath;
  int _cacheEntryCount = 0;
  int _cacheBytes = 0;
  bool _translationEnabled = false;
  bool _subtitleCacheEnabled = true;
  bool _translationDisclosureAccepted = false;
  bool _initialized = false;
  bool _disposed = false;
  bool _lifecycleSuspended = false;

  List<String> get playlist => List<String>.unmodifiable(_playlist);

  Map<String, String> get playlistStatus =>
      Map<String, String>.unmodifiable(_playlistStatus);

  int get currentPlaylistIndex => _currentPlaylistIndex;

  String? get processingPath => _processingPath;

  String? get cacheDirectory => _cacheDirectory;

  int get cacheEntryCount => _cacheEntryCount;

  int get cacheBytes => _cacheBytes;

  bool get translationEnabled => _translationEnabled;

  bool get subtitleCacheEnabled => _subtitleCacheEnabled;

  bool get lifecycleSuspended => _lifecycleSuspended;

  VideoSubtitleCache get subtitleCache => _subtitleCache;

  TranscriptionResult? resultFor(String path) => _playlistResults[path];

  Set<String> get protectedCachePaths => <String>{
    if (controller.filePath != null) controller.filePath!,
    ..._partialPlaylistResults,
    ..._cacheWritePaths,
  };

  void init() {
    if (_initialized || _disposed) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_onVideoChanged);
    transcription.addListener(onTranscriptionChanged);
    transcription.scheduler.addListener(onSchedulerChanged);
    unawaited(_loadPlaylist());
  }

  Future<void> loadCacheDirectory() async {
    try {
      _cacheDirectory = await _subtitleCache.directoryPath();
      _notifyListeners();
    } on Object {
      // 路径仅用于提示；实际缓存时会再次尝试创建目录。
    }
  }

  void setProcessingPreferences({
    required bool translationEnabled,
    required bool cacheEnabled,
  }) {
    _translationEnabled = translationEnabled;
    _subtitleCacheEnabled = cacheEnabled;
    _notifyListeners();
  }

  void setTranslationEnabled(bool enabled) {
    _translationEnabled = enabled;
    _notifyListeners();
    if (enabled) requestPlaylistProcessing();
  }

  void setSubtitleCacheEnabled(bool enabled) {
    _subtitleCacheEnabled = enabled;
    _notifyListeners();
    if (enabled) requestPlaylistProcessing();
  }

  Future<void> _loadPlaylist() async {
    try {
      final List<String> saved = await _playlistStore.read();
      if (_disposed || saved.isEmpty || _playlist.isNotEmpty) return;
      final String? currentPath = controller.filePath;
      _playlist.addAll(saved);
      for (final String path in saved) {
        _playlistStatus[path] = '等待播放';
      }
      _currentPlaylistIndex = currentPath == null
          ? -1
          : _playlist.indexOf(currentPath);
      _notifyListeners();
    } on Object {
      // 播放列表是辅助状态，损坏或暂不可用时保持空列表。
    }
  }

  void _persistPlaylist() {
    unawaited(() async {
      try {
        await _playlistStore.write(List<String>.of(_playlist));
      } on Object {
        // 播放列表持久化失败不应影响当前播放或转写。
      }
    }());
  }

  Future<void> refreshCacheSummary() async {
    try {
      final VideoSubtitleCacheSummary summary = await _subtitleCache.inspect();
      if (_disposed) return;
      _cacheEntryCount = summary.entries.length;
      _cacheBytes = summary.bytes;
      _notifyListeners();
    } on Object {
      // 缓存统计只用于界面展示，读取失败时保留上次数值。
    }
  }

  Future<void> replaceWith(String path, {TranscriptionResult? result}) async {
    final String value = path.trim();
    if (value.isEmpty || _disposed) return;
    if (result != null) _playlistResults[value] = result;
    _partialPlaylistResults.remove(value);
    _playlistGeneration++;
    _playlist
      ..clear()
      ..add(value);
    _currentPlaylistIndex = 0;
    _cancelledPlaylistPaths.clear();
    _notifyListeners();
    _persistPlaylist();
    await openPlaylistVideo(0);
  }

  Future<void> addPaths(Iterable<String> paths) async {
    if (_disposed) return;
    final Set<String> known = _playlist.toSet();
    final List<String> additions = paths
        .map((String path) => path.trim())
        .where((String path) => path.isNotEmpty && known.add(path))
        .toList(growable: false);
    if (additions.isEmpty) return;
    final bool openFirst = _currentPlaylistIndex < 0;
    _playlistGeneration++;
    _playlist.addAll(additions);
    for (final String path in additions) {
      _playlistStatus[path] = '等待播放';
    }
    _cancelledPlaylistPaths.removeAll(additions);
    _notifyListeners();
    _persistPlaylist();
    if (openFirst) {
      await openPlaylistVideo(0);
    } else {
      requestPlaylistProcessing();
    }
  }

  Future<void> openPlaylistVideo(int index, {bool autoplay = false}) async {
    if (_disposed || index < 0 || index >= _playlist.length) return;
    final String path = _playlist[index];
    final TranscriptionResult? linked = transcription.filePath == path
        ? transcription.result
        : null;
    if (linked != null) _playlistResults[path] = linked;
    _partialPlaylistResults.remove(path);
    _playlistGeneration++;
    _currentPlaylistIndex = index;
    _notifyListeners();
    await controller.open(path);
    if (_disposed) return;
    if (autoplay && controller.filePath == path && !controller.playing) {
      await controller.playOrPause();
    }
    requestPlaylistProcessing();
  }

  void cancelPlaylistItem(int index) {
    if (_disposed || index < 0 || index >= _playlist.length) return;
    final String path = _playlist[index];
    _cancelledPlaylistPaths.add(path);
    if (_processingPath == path) {
      _playlistGeneration++;
      _processingRequested = false;
      _waitingForTranscription = false;
    }
    _setPlaylistStatus(path, '已取消');
  }

  void retryPlaylistItem(int index) {
    if (_disposed || index < 0 || index >= _playlist.length) return;
    final String path = _playlist[index];
    _cancelledPlaylistPaths.remove(path);
    _playlistResults.remove(path);
    _partialPlaylistResults.remove(path);
    _translationWarnings.remove(path);
    if (_processingPath == path) _playlistGeneration++;
    _setPlaylistStatus(path, '等待重试');
    if (_currentPlaylistIndex < 0 || index < _currentPlaylistIndex) {
      unawaited(openPlaylistVideo(index));
    } else {
      requestPlaylistProcessing();
    }
  }

  void reorderPlaylist(int oldIndex, int newIndex) {
    if (_disposed ||
        oldIndex == newIndex ||
        oldIndex < 0 ||
        oldIndex >= _playlist.length ||
        newIndex < 0 ||
        newIndex > _playlist.length) {
      return;
    }
    final String? currentPath = controller.filePath;
    final String path = _playlist.removeAt(oldIndex);
    _playlist.insert(newIndex, path);
    _playlistGeneration++;
    _currentPlaylistIndex = currentPath == null
        ? -1
        : _playlist.indexOf(currentPath);
    _notifyListeners();
    _persistPlaylist();
    requestPlaylistProcessing();
  }

  Future<void> removePlaylistItem(int index) async {
    if (_disposed || index < 0 || index >= _playlist.length) return;
    final String path = _playlist[index];
    final bool wasCurrent = index == _currentPlaylistIndex;
    _playlistGeneration++;
    _playlist.removeAt(index);
    _playlistResults.remove(path);
    _partialPlaylistResults.remove(path);
    _playlistStatus.remove(path);
    _translationWarnings.remove(path);
    _cancelledPlaylistPaths.remove(path);
    int nextIndex = _currentPlaylistIndex;
    if (_playlist.isEmpty) {
      nextIndex = -1;
    } else if (wasCurrent) {
      nextIndex = index < _playlist.length ? index : _playlist.length - 1;
    } else if (index < _currentPlaylistIndex) {
      nextIndex--;
    }
    _currentPlaylistIndex = nextIndex;
    _notifyListeners();
    _persistPlaylist();
    if (wasCurrent && nextIndex >= 0) {
      await openPlaylistVideo(nextIndex);
    } else {
      requestPlaylistProcessing();
    }
  }

  void _onVideoChanged() {
    if (_disposed ||
        _autoAdvancing ||
        _currentPlaylistIndex < 0 ||
        _currentPlaylistIndex + 1 >= _playlist.length) {
      return;
    }
    final Duration duration = controller.duration;
    if (duration <= Duration.zero ||
        controller.position < duration - const Duration(milliseconds: 250)) {
      return;
    }
    _autoAdvancing = true;
    unawaited(
      openPlaylistVideo(_currentPlaylistIndex + 1, autoplay: true).whenComplete(
        () {
          _autoAdvancing = false;
        },
      ),
    );
  }

  void onTranscriptionChanged() {
    if (!_waitingForTranscription || transcription.busy || _disposed) return;
    _waitingForTranscription = false;
    requestPlaylistProcessing();
  }

  void onSchedulerChanged() {
    if (!_waitingForTranscription ||
        transcription.scheduler.active != null ||
        transcription.busy ||
        _disposed) {
      return;
    }
    _waitingForTranscription = false;
    requestPlaylistProcessing();
  }

  void requestPlaylistProcessing() {
    if (_disposed) return;
    _processingRequested = true;
    if (_lifecycleSuspended || _processingFuture != null) return;
    final Future<void> future = _drainPlaylistProcessing();
    _processingFuture = future;
    unawaited(
      future.whenComplete(() {
        _processingFuture = null;
        if (_processingRequested && !_disposed) requestPlaylistProcessing();
      }),
    );
  }

  Future<void> _drainPlaylistProcessing() async {
    while (_processingRequested && !_disposed && !_lifecycleSuspended) {
      _processingRequested = false;
      await _processPlaylist(_playlistGeneration);
    }
  }

  Future<void> _processPlaylist(int generation) async {
    if (_disposed ||
        _lifecycleSuspended ||
        _currentPlaylistIndex < 0 ||
        _currentPlaylistIndex >= _playlist.length) {
      return;
    }
    final List<String> paths = <String>[
      _playlist[_currentPlaylistIndex],
      if (_subtitleCacheEnabled) ..._playlist.skip(_currentPlaylistIndex + 1),
    ];
    final AppSettingsRepository? configuredRepository = settings;
    final TranslationApiSettings translationSettings =
        configuredRepository == null
        ? const TranslationApiSettings()
        : await configuredRepository.loadTranslationApiSettings();
    final String cacheScope = videoSubtitleCacheScope(translationSettings);
    TranslationProvider? provider;
    bool providerResolved = false;

    Future<TranslationProvider?> resolveProvider() async {
      if (providerResolved) return provider;
      providerResolved = true;
      provider = translationProviderResolver == null
          ? await _loadTranslationProvider(
              configuredRepository ?? AppSettingsRepository(),
              translationSettings,
            )
          : await translationProviderResolver!();
      return provider;
    }

    try {
      for (final String path in paths) {
        if (_disposed || generation != _playlistGeneration) return;
        if (_cancelledPlaylistPaths.contains(path)) continue;
        TranscriptionResult? result = _partialPlaylistResults.contains(path)
            ? null
            : _playlistResults[path];
        TranscriptionResult? resumeResult;
        Duration resumeAt = Duration.zero;
        Future<TranscriptionResult?>? cacheRead;
        Future<VideoSubtitleCheckpoint?>? checkpointRead;
        if (result == null && _subtitleCacheEnabled) {
          cacheRead = _subtitleCache.read(path, configurationScope: cacheScope);
          checkpointRead = _subtitleCache.readCheckpoint(
            path,
            configurationScope: cacheScope,
          );
          result = await cacheRead;
          if (result != null) {
            _partialPlaylistResults.remove(path);
            storePlaylistResult(path, result);
            _setPlaylistStatus(path, '已载入字幕缓存');
          }
        }
        if (result == null && _subtitleCacheEnabled) {
          final VideoSubtitleCheckpoint? checkpoint = await checkpointRead;
          if (checkpoint != null && checkpoint.processedSamples > 0) {
            resumeResult = checkpoint.result;
            resumeAt = Duration(
              microseconds:
                  checkpoint.processedSamples *
                  Duration.microsecondsPerSecond ~/
                  kSampleRate,
            );
            _partialPlaylistResults.add(path);
            storePlaylistResult(path, checkpoint.result);
            _setPlaylistStatus(path, '从字幕检查点继续');
          }
        }
        if (result == null) {
          if (transcription.busy) {
            _waitingForTranscription = true;
            _setPlaylistStatus(path, '等待当前转写任务结束');
            return;
          }
          _setPlaylistStatus(
            path,
            path == controller.filePath ? '实时转写中' : '后台预转写中',
          );
          final bool isCurrentVideo = path == controller.filePath;
          final TranscriptionTaskPriority taskPriority = isCurrentVideo
              ? TranscriptionTaskPriority.currentVideo
              : TranscriptionTaskPriority.backgroundCache;
          _processingPath = path;
          _notifyListeners();
          double lastCheckpointSeconds = resumeAt.inMicroseconds / 1000000;
          Future<void> checkpointWrite = Future<void>.value();

          void scheduleCheckpoint(TranscriptionResult value) {
            if (!_subtitleCacheEnabled ||
                generation != _playlistGeneration ||
                value.duration - lastCheckpointSeconds < 30) {
              return;
            }
            lastCheckpointSeconds = value.duration;
            _partialPlaylistResults.add(path);
            final int processedSamples = (value.duration * kSampleRate).round();
            checkpointWrite = checkpointWrite
                .then<void>(
                  (_) => _subtitleCache.writeCheckpoint(
                    path,
                    value,
                    processedSamples: processedSamples,
                    configurationScope: cacheScope,
                  ),
                )
                .catchError((Object _) {});
          }

          Future<void> persistCheckpointNow() async {
            if (!_subtitleCacheEnabled || generation != _playlistGeneration) {
              return;
            }
            final TranscriptionResult? value = _playlistResults[path];
            if (value == null) return;
            final int processedSamples = (value.duration * kSampleRate).round();
            final int resumeSamples =
                (resumeAt.inMicroseconds *
                kSampleRate ~/
                Duration.microsecondsPerSecond);
            if (processedSamples <= resumeSamples) return;
            _partialPlaylistResults.add(path);
            await checkpointWrite;
            try {
              await _subtitleCache.writeCheckpoint(
                path,
                value,
                processedSamples: processedSamples,
                configurationScope: cacheScope,
              );
            } on Object {
              // 检查点只是恢复加速；写入失败不应覆盖真正的转写错误。
            }
          }

          try {
            result = await transcription.transcribeVideoStream(
              path,
              taskPriority: taskPriority,
              initialResult: resumeResult,
              startAt: resumeAt,
              onUpdate: (TranscriptionResult update) {
                if (_disposed || generation != _playlistGeneration) return;
                final TranscriptionResult merged = _mergeTranslations(
                  update,
                  _playlistResults[path],
                );
                storePlaylistResult(path, merged);
                scheduleCheckpoint(merged);
                if (_translationEnabled) {
                  _queueMissingTranslations(
                    path,
                    resolveProvider,
                    translationSettings.targetLanguage,
                    generation,
                  );
                }
              },
              isCancelled: () =>
                  _disposed ||
                  generation != _playlistGeneration ||
                  _lifecycleSuspended,
            );
            await checkpointWrite;
            result = _mergeTranslations(result, _playlistResults[path]);
            _partialPlaylistResults.remove(path);
            storePlaylistResult(path, result);
          } on Object catch (error) {
            if (_disposed || generation != _playlistGeneration) return;
            await persistCheckpointNow();
            if (_lifecycleSuspended) {
              _partialPlaylistResults.add(path);
              _setPlaylistStatus(path, '应用已暂停，字幕检查点已保存，唤醒后继续');
              _processingPath = null;
              _notifyListeners();
              return;
            }
            if (error is TranscriptionTaskPreempted) {
              _partialPlaylistResults.add(path);
              _waitingForTranscription = true;
              _setPlaylistStatus(
                path,
                isCurrentVideo ? '当前视频转写已暂停，等待高优先级任务结束' : '后台预转写已暂停，等待高优先级任务结束',
              );
              _processingPath = null;
              _notifyListeners();
              return;
            }
            if (transcription.busy &&
                error is StateError &&
                error.message == '当前正在处理另一个文件') {
              _waitingForTranscription = true;
              _setPlaylistStatus(path, '等待当前转写任务结束');
              _processingPath = null;
              _notifyListeners();
              return;
            }
            _setPlaylistStatus(path, '转写失败：${_playlistError(error)}');
            _processingPath = null;
            continue;
          }
        }
        if (_translationEnabled) {
          _queueMissingTranslations(
            path,
            resolveProvider,
            translationSettings.targetLanguage,
            generation,
          );
          await _translationQueue;
          result = _playlistResults[path] ?? result;
        }
        if (_subtitleCacheEnabled && result.segments.isNotEmpty) {
          try {
            _cacheWritePaths.add(path);
            final String saved = await _subtitleCache.write(
              path,
              result,
              configurationScope: cacheScope,
            );
            _cacheDirectory = p.dirname(saved);
            _partialPlaylistResults.remove(path);
            _setPlaylistReadyStatus(path, '字幕已缓存');
            await _subtitleCache.trimToMaxBytes(
              kDefaultVideoSubtitleCacheMaxBytes,
              protectedMediaPaths: protectedCachePaths,
            );
            unawaited(refreshCacheSummary());
          } on Object catch (error) {
            _setPlaylistReadyStatus(path, '字幕可用，缓存失败：$error');
          } finally {
            _cacheWritePaths.remove(path);
          }
        } else {
          _setPlaylistReadyStatus(path, '字幕已就绪');
        }
        if (path == controller.filePath && !transcription.busy) {
          transcription.applyImportedResult(result, mediaPath: path);
        }
        _processingPath = null;
        _notifyListeners();
      }
    } finally {
      _processingPath = null;
      _notifyListeners();
      if (provider is ClosableTranslationProvider) {
        (provider as ClosableTranslationProvider).close();
      }
    }
  }

  void _queueMissingTranslations(
    String path,
    Future<TranslationProvider?> Function() resolveProvider,
    String targetLanguage,
    int generation,
  ) {
    _translationQueue = _translationQueue
        .then<void>((_) async {
          if (!_translationEnabled || generation != _playlistGeneration) return;
          final TranscriptionResult? source = _playlistResults[path];
          if (source == null) return;
          final List<int> missing = <int>[];
          for (int index = 0; index < source.segments.length; index++) {
            final Segment segment = source.segments[index];
            if (segment.isFinal &&
                segment.text.trim().isNotEmpty &&
                segment.translation?.trim().isEmpty != false &&
                !_isChineseSegment(segment, source.language)) {
              missing.add(index);
            }
          }
          if (missing.isEmpty) {
            _setTranslationWarning(path, null);
            return;
          }
          if (!await ensureTranslationDisclosure()) return;
          final TranslationProvider? translator = await resolveProvider();
          if (translator == null) {
            _setTranslationWarning(path, '未配置翻译 API Key');
            return;
          }
          for (final int index in missing) {
            if (!_translationEnabled || generation != _playlistGeneration) {
              return;
            }
            final TranscriptionResult? current = _playlistResults[path];
            if (current == null || index >= current.segments.length) return;
            final Segment segment = current.segments[index];
            final List<String> translated = await translateTexts(
              translator,
              <String>[segment.text],
              from: segment.language.trim().isEmpty
                  ? current.language
                  : segment.language,
              to: targetLanguage,
              isCancelled: () =>
                  _disposed ||
                  !_translationEnabled ||
                  generation != _playlistGeneration,
            );
            final List<Segment> segments = <Segment>[...current.segments];
            segments[index] = segment.copyWith(
              translation: translated.single.trim(),
            );
            storePlaylistResult(path, current.copyWith(segments: segments));
          }
          _setTranslationWarning(path, null);
        })
        .catchError((Object error) {
          if (error is TranslationCancelledException) return;
          _setTranslationWarning(path, '翻译失败：$error');
        });
  }

  Future<bool> ensureTranslationDisclosure() async {
    if (_translationDisclosureAccepted) return true;
    if (_disposed || requestTranslationDisclosure == null) return false;
    final bool confirmed = await requestTranslationDisclosure!();
    if (_disposed) return false;
    if (confirmed) {
      _translationDisclosureAccepted = true;
      return true;
    }
    _translationEnabled = false;
    _notifyListeners();
    final TranslationPreferenceChanged? callback =
        onTranslationPreferenceChanged;
    if (callback != null) unawaited(callback(false));
    return false;
  }

  void storePlaylistResult(String path, TranscriptionResult result) {
    if (_disposed) return;
    _playlistResults[path] = result;
    _notifyListeners();
  }

  void _setPlaylistStatus(String path, String status) {
    if (_disposed) return;
    _playlistStatus[path] = status;
    _notifyListeners();
  }

  void _setTranslationWarning(String path, String? warning) {
    if (_disposed) return;
    if (warning == null) {
      _translationWarnings.remove(path);
    } else {
      _translationWarnings[path] = warning;
      _setPlaylistStatus(path, '字幕已就绪；$warning');
    }
    _notifyListeners();
  }

  void _setPlaylistReadyStatus(String path, String status) {
    final String? warning = _translationWarnings[path];
    _setPlaylistStatus(path, warning == null ? status : '$status；$warning');
  }

  String _playlistError(Object error) {
    final String raw = error is StateError ? error.message : '$error';
    return raw.replaceFirst(RegExp(r'^(Bad state: |Exception: )+'), '');
  }

  String videoSubtitleCacheScope(TranslationApiSettings translationSettings) {
    final Map<String, Object?> scope = <String, Object?>{
      'asr': transcription.config.toJson(),
      'translation': _translationEnabled
          ? <String, String>{
              'endpoint': translationSettings.endpoint.trim(),
              'model': translationSettings.model.trim(),
              'target_language': translationSettings.targetLanguage.trim(),
              'glossary': translationSettings.glossary,
            }
          : null,
    };
    return sha256.convert(utf8.encode(jsonEncode(scope))).toString();
  }

  TranscriptionResult _mergeTranslations(
    TranscriptionResult source,
    TranscriptionResult? previous,
  ) {
    if (previous == null) return source;
    final Map<String, String> translations = <String, String>{
      for (final Segment segment in previous.segments)
        if (segment.translation?.trim().isNotEmpty == true)
          _segmentKey(segment): segment.translation!.trim(),
    };
    return source.copyWith(
      segments: source.segments
          .map(
            (Segment segment) => translations[_segmentKey(segment)] == null
                ? segment
                : segment.copyWith(
                    translation: translations[_segmentKey(segment)],
                  ),
          )
          .toList(growable: false),
    );
  }

  Future<void> writeSubtitleCache(
    String path,
    TranscriptionResult result,
  ) async {
    if (_disposed || !_subtitleCacheEnabled) return;
    try {
      final TranslationApiSettings translationSettings = settings == null
          ? const TranslationApiSettings()
          : await settings!.loadTranslationApiSettings();
      _cacheWritePaths.add(path);
      try {
        final String saved = await _subtitleCache.write(
          path,
          result,
          configurationScope: videoSubtitleCacheScope(translationSettings),
        );
        _cacheDirectory = p.dirname(saved);
        await _subtitleCache.trimToMaxBytes(
          kDefaultVideoSubtitleCacheMaxBytes,
          protectedMediaPaths: protectedCachePaths,
        );
        _setPlaylistReadyStatus(path, '字幕已缓存');
      } finally {
        _cacheWritePaths.remove(path);
      }
      unawaited(refreshCacheSummary());
    } on Object catch (error) {
      _setPlaylistReadyStatus(path, '字幕可用，缓存失败：$error');
    }
  }

  Future<VideoSubtitleCacheSummary> inspectCache(
    TranslationApiSettings translationSettings,
  ) {
    return _subtitleCache.inspect(
      configurationScope: videoSubtitleCacheScope(translationSettings),
    );
  }

  Future<TranslationProvider?> _loadTranslationProvider(
    AppSettingsRepository repository,
    TranslationApiSettings settings,
  ) async {
    final String? apiKey = await repository.translationSecrets.readApiKey();
    if (apiKey == null) return null;
    return ApiTranslationProvider(
      apiKey: apiKey,
      endpoint: settings.endpoint,
      model: settings.model,
      glossary: settings.glossary,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      if (!_lifecycleSuspended) return;
      _lifecycleSuspended = false;
      _notifyListeners();
      if (_processingRequested || _processingPath != null) {
        requestPlaylistProcessing();
      }
      return;
    }
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    if (_lifecycleSuspended) return;
    _lifecycleSuspended = true;
    if (_processingFuture != null ||
        _processingRequested ||
        _processingPath != null) {
      _processingRequested = true;
      final String? path = _processingPath;
      if (path != null) {
        _setPlaylistStatus(path, '应用即将暂停，正在保存字幕检查点');
      }
    }
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _playlistGeneration++;
    if (_initialized) {
      WidgetsBinding.instance.removeObserver(this);
      controller.removeListener(_onVideoChanged);
      transcription.removeListener(onTranscriptionChanged);
      transcription.scheduler.removeListener(onSchedulerChanged);
    }
    super.dispose();
  }
}

String _segmentKey(Segment segment) =>
    '${segment.index}:${segment.start}:${segment.end}:${segment.text}';

bool _isChineseSegment(Segment segment, String fallbackLanguage) {
  final String language =
      (segment.language.trim().isEmpty ? fallbackLanguage : segment.language)
          .trim()
          .toLowerCase();
  return language == 'zh' ||
      language == 'zh-cn' ||
      language == 'zh-tw' ||
      language == 'cmn' ||
      language == 'yue' ||
      language.startsWith('zh-');
}
