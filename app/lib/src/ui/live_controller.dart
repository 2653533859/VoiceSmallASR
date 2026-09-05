/// 实时字幕的状态机：麦克风 → 识别 isolate → 临时/定稿两类段。
///
/// 与 [TranscribeController] 的分工：那边管文件转写，这边管麦克风；
/// 两边**共用同一个识别 worker**（模型只加载一次），因此本类不自己起 isolate，
/// 而是通过 [provideWorker] 借用。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';
import 'package:vsasr_app/src/audio/microphone.dart';
import 'package:vsasr_app/src/diagnostics/performance_report.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/ui/transcription_task_scheduler.dart';

/// 借用识别器。返回 null 表示模型没准备好（原因由提供方自己展示）。
typedef WorkerProvider = Future<Transcriber?> Function();

/// 释放借用的识别器。
typedef WorkerReleaser = void Function(Transcriber worker);

/// 当前识别语言，只用于导出结果里的 `language` 字段。
typedef LanguageOf = String Function();

/// 按需创建实时翻译 provider；返回 null 表示尚未配置 API Key。
typedef TranslationProviderResolver = Future<TranslationProvider?> Function();

/// 录音阶段。
enum LiveStage {
  idle,

  /// 正在借 worker、申请权限、打开设备。
  starting,

  /// 录音中。
  recording,

  /// 正在收尾（停设备、把尾句解码出来）。
  stopping,
}

/// 实时字幕状态。
class LiveController extends ChangeNotifier {
  LiveController({
    required this.provideWorker,
    this.releaseWorker,
    this.discardWorker,
    this.operationTimeout = const Duration(seconds: 10),
    this.maxPendingAudio = const Duration(seconds: 5),
    required this.languageOf,
    this.provideTranslationProvider,
    this.translationRequestPolicy = const TranslationRequestPolicy(),
    String translationTargetLanguage = 'zh-CN',
    AudioSource? mic,
    this.scheduler,
  }) : _mic = mic ?? MicrophoneSource() {
    final String target = translationTargetLanguage.trim();
    if (target.isEmpty) {
      throw ArgumentError.value(
        translationTargetLanguage,
        'translationTargetLanguage',
        '目标语言不能为空',
      );
    }
    _translationTargetLanguage = target;
  }

  final WorkerProvider provideWorker;
  final WorkerReleaser? releaseWorker;
  final Future<void> Function(Transcriber worker)? discardWorker;
  final Duration operationTimeout;
  final Duration maxPendingAudio;
  final LanguageOf languageOf;
  final TranslationProviderResolver? provideTranslationProvider;
  final TranslationRequestPolicy translationRequestPolicy;
  final TranscriptionTaskScheduler? scheduler;
  late String _translationTargetLanguage;
  final AudioSource _mic;

  Transcriber? _activeWorker;
  final List<Segment> _finals = <Segment>[];
  Segment? _partial;
  LiveSession? _session;
  StreamSubscription<Segment>? _segments;
  StreamSubscription<Float32List>? _audio;
  final Queue<Float32List> _pendingAudio = Queue<Float32List>();
  Future<void>? _audioPump;
  int _audioGeneration = 0;
  Future<void>? _tearingDown;
  int _pendingSamples = 0;
  int _peakPendingSamples = 0;
  Duration _maxAcceptLatency = Duration.zero;
  int _overloadCount = 0;
  bool _workerUnhealthy = false;

  /// 包括当前正在消费的块，按实际收到但尚未确认消费的采样点计量。
  Duration get pendingAudioDuration =>
      Duration(microseconds: (_pendingSamples * 1000000 / kSampleRate).round());
  Duration get peakPendingAudioDuration => Duration(
    microseconds: (_peakPendingSamples * 1000000 / kSampleRate).round(),
  );
  Duration get maxAcceptLatency => _maxAcceptLatency;
  int get overloadCount => _overloadCount;
  Future<void>? _translationQueue;
  int _translationGeneration = 0;
  TranslationProvider? _translationProvider;
  Object? _translationProviderError;
  StackTrace? _translationProviderErrorStack;
  bool _translationProviderResolved = false;
  final Set<String> _retryingTranslations = <String>{};
  final Set<String> _failedTranslations = <String>{};

  LiveStage _stage = LiveStage.idle;
  String? _errorText;
  bool _disposed = false;
  bool _translationEnabled = false;
  Stopwatch? _performanceWatch;
  int _audioSamples = 0;
  LivePerformanceReport? _performanceReport;
  TranscriptionTaskLease? _taskLease;
  int _startGeneration = 0;

  LiveStage get stage => _stage;

  bool get recording => _stage == LiveStage.recording;

  /// 忙碌时界面应禁用「开始/停止」以外的操作。
  bool get busy => _stage != LiveStage.idle;

  /// 已定稿的句子，按时间顺序。
  List<Segment> get finals => List<Segment>.unmodifiable(_finals);

  /// 当前这句的临时结果；下一次刷新会替换它，定稿后清空。
  Segment? get partial => _partial;

  String? get errorText => _errorText;

  /// 最近一次成功收尾的实时字幕性能报告；正在录音或尚未录音时为 null。
  LivePerformanceReport? get performanceReport => _performanceReport;

  /// 是否在定稿字幕后自动请求第三方翻译 API。
  bool get translationEnabled => _translationEnabled;

  String get translationTargetLanguage => _translationTargetLanguage;

  void setTranslationTargetLanguage(String value) {
    final String target = value.trim();
    if (target.isEmpty) {
      throw ArgumentError.value(value, 'translationTargetLanguage', '目标语言不能为空');
    }
    _translationTargetLanguage = target;
  }

  bool get hasResult => _finals.isNotEmpty;

  bool isRetrying(Segment segment) =>
      _retryingTranslations.contains(_segmentKey(segment));

  bool canRetryTranslation(Segment segment) =>
      _failedTranslations.contains(_segmentKey(segment));

  /// 面向用户的一行状态。
  String get statusText => switch (_stage) {
    LiveStage.starting => '正在准备麦克风…',
    LiveStage.recording => '录音中　已定稿 ${_finals.length} 句',
    LiveStage.stopping => '正在收尾…',
    LiveStage.idle => _finals.isEmpty ? '' : '已停止　共 ${_finals.length} 句',
  };

  /// 把定稿句子拼成可导出的结果。
  TranscriptionResult get result => TranscriptionResult(
    segments: List<Segment>.unmodifiable(_finals),
    duration: _finals.isEmpty ? 0.0 : _finals.last.end,
    language: languageOf(),
  );

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// 开始录音。权限、设备、模型任一不就绪都会写进 [errorText] 并回到空闲。
  Future<void> start() async {
    if (_stage != LiveStage.idle) return;
    final int generation = ++_startGeneration;
    _resetTranslationProvider();
    _performanceReport = null;
    _audioSamples = 0;
    _pendingSamples = 0;
    _peakPendingSamples = 0;
    _maxAcceptLatency = Duration.zero;
    _overloadCount = 0;
    _workerUnhealthy = false;
    _stage = LiveStage.starting;
    _errorText = null;
    notifyListeners();
    try {
      final TranscriptionTaskScheduler? taskScheduler = scheduler;
      if (taskScheduler != null) {
        _taskLease = await taskScheduler.acquire(
          priority: TranscriptionTaskPriority.live,
          label: '实时字幕',
        );
      }
      if (_disposed ||
          generation != _startGeneration ||
          _stage != LiveStage.starting) {
        _releaseTaskLease();
        return;
      }
      final Transcriber? worker = await provideWorker();
      if (worker == null) throw StateError('模型未就绪，先在「文件转写」页把模型下载好');
      _activeWorker = worker;
      if (_disposed ||
          generation != _startGeneration ||
          _stage != LiveStage.starting) {
        _teardownWorker();
        _releaseTaskLease();
        return;
      }

      final LiveSession session = await worker.startLive().timeout(
        operationTimeout,
      );
      if (_disposed ||
          generation != _startGeneration ||
          _stage != LiveStage.starting) {
        await session.finish().timeout(operationTimeout);
        _teardownWorker();
        _releaseTaskLease();
        return;
      }
      _session = session;
      _segments = session.segments.listen(_onSegment, onError: _onStreamError);

      // 先开会话再开设备：反过来的话，最早的几块音频会没人接。
      final Stream<Float32List> audio = await _mic.start();
      if (_disposed ||
          generation != _startGeneration ||
          _stage != LiveStage.starting) {
        await _teardown();
        _releaseTaskLease();
        return;
      }
      _audio = audio.listen(_enqueueAudio, onError: _onStreamError);
      _performanceWatch = Stopwatch()..start();
      _stage = LiveStage.recording;
    } on Object catch (error) {
      _workerUnhealthy = true;
      _errorText = _humanize(error);
      await _teardown();
      _translationGeneration++;
      await _awaitTranslationQueue();
      _closeTranslationProvider();
      _performanceWatch = null;
      _audioSamples = 0;
      _performanceReport = null;
      _stage = LiveStage.idle;
      _releaseTaskLease();
    }
    notifyListeners();
  }

  /// 停止录音。会等尾句解码完 —— 那一句往往正是用户最后说的话。
  Future<void> stop() async {
    if (_stage != LiveStage.recording) return;
    _stage = LiveStage.stopping;
    notifyListeners();
    try {
      await _teardown();
    } on Object catch (error) {
      _errorText = _humanize(error);
    }
    _partial = null;
    final Stopwatch? performanceWatch = _performanceWatch;
    performanceWatch?.stop();
    if (performanceWatch != null) {
      _performanceReport = LivePerformanceReport(
        generatedAt: DateTime.now(),
        platform: Platform.operatingSystem,
        language: languageOf(),
        audioDuration: _audioSamples / kSampleRate,
        sampleCount: _audioSamples,
        segmentCount: _finals.length,
        elapsed: performanceWatch.elapsed,
        peakPendingAudioDuration: peakPendingAudioDuration,
        maxAcceptLatency: maxAcceptLatency,
        overloadCount: overloadCount,
      );
    }
    // 使尚未开始的排队请求失效；当前正在进行的请求最多只需等待一次超时。
    _translationGeneration++;
    _releaseTaskLease();
    await _awaitTranslationQueue();
    _closeTranslationProvider();
    _performanceWatch = null;
    _stage = LiveStage.idle;
    notifyListeners();
  }

  /// 清空已识别的内容，准备下一场。
  void clear() {
    if (busy) return;
    _finals.clear();
    _partial = null;
    _errorText = null;
    _performanceReport = null;
    _performanceWatch = null;
    _audioSamples = 0;
    _retryingTranslations.clear();
    _failedTranslations.clear();
    notifyListeners();
  }

  /// 重试单条实时字幕翻译；失败只更新错误提示，不修改原文段。
  Future<void> retryTranslation(Segment segment) async {
    if (_disposed) return;
    final String key = _segmentKey(segment);
    if (!_failedTranslations.contains(key) ||
        _retryingTranslations.contains(key)) {
      return;
    }
    _retryingTranslations.add(key);
    _errorText = null;
    notifyListeners();
    final Future<void> previous = _translationQueue ?? Future<void>.value();
    final Future<void> task = previous.then<void>((_) async {
      try {
        await _translateFinal(segment, _translationGeneration);
      } on TranslationCancelledException {
        // 用户关闭实时翻译或会话已结束，不把取消显示为翻译失败。
      } on Object catch (error) {
        if (!_disposed) {
          _failedTranslations.add(key);
          _errorText = _humanize(error);
        }
      } finally {
        _retryingTranslations.remove(key);
        notifyListeners();
      }
    });
    _translationQueue = task;
    await task;
  }

  /// 开关实时翻译。关闭只停止后续请求，不清除已经得到的译文。
  void setTranslationEnabled(bool enabled) {
    if (_translationEnabled == enabled) return;
    _translationEnabled = enabled;
    _translationGeneration++;
    notifyListeners();
  }

  /// 把结果渲染成指定格式（`srt`/`vtt`/`json`/`txt`）。落盘由界面层负责。
  String renderResult(String format) {
    if (_finals.isEmpty) throw StateError('还没有可导出的识别结果');
    return renderSubtitles(result, format);
  }

  void _onSegment(Segment segment) {
    if (segment.isFinal) {
      _finals.add(segment);
      _partial = null;
      if (_translationEnabled) {
        _queueTranslation(segment, _translationGeneration);
      }
    } else {
      _partial = segment;
    }
    notifyListeners();
  }

  void _queueTranslation(Segment segment, int generation) {
    final Future<void> previous = _translationQueue ?? Future<void>.value();
    _translationQueue = previous.then<void>((_) async {
      try {
        await _translateFinal(segment, generation);
      } on TranslationCancelledException {
        // 同上：重试期间关闭翻译不留下失败标记。
      } on Object catch (error) {
        if (_disposed) return;
        _failedTranslations.add(_segmentKey(segment));
        _errorText = _humanize(error);
        notifyListeners();
      }
    });
  }

  Future<void> _translateFinal(Segment segment, int generation) async {
    final TranslationProviderResolver? resolver = provideTranslationProvider;
    if (resolver == null ||
        !_translationEnabled ||
        generation != _translationGeneration) {
      return;
    }
    final TranslationProvider? provider = await _resolveTranslationProvider(
      resolver,
    );
    if (provider == null) throw StateError('请先在设置中保存第三方翻译 API Key');
    if (_disposed ||
        !_translationEnabled ||
        generation != _translationGeneration) {
      return;
    }
    final String source = segment.language.trim().isEmpty
        ? languageOf()
        : segment.language;
    final List<String> translated = await translateTexts(
      provider,
      <String>[segment.text],
      from: source,
      to: _translationTargetLanguage,
      policy: translationRequestPolicy,
      isCancelled: () =>
          _disposed ||
          !_translationEnabled ||
          generation != _translationGeneration,
    );
    if (_disposed ||
        !_translationEnabled ||
        generation != _translationGeneration) {
      return;
    }
    final int index = _finals.indexWhere(
      (Segment value) =>
          value.index == segment.index &&
          value.start == segment.start &&
          value.end == segment.end,
    );
    if (index < 0) return;
    _finals[index] = _finals[index].copyWith(
      translation: translated.single.trim(),
    );
    _failedTranslations.remove(_segmentKey(segment));
    notifyListeners();
  }

  String _segmentKey(Segment segment) =>
      '${segment.index}:${segment.start}:${segment.end}';

  void _onStreamError(Object error) {
    _workerUnhealthy = true;
    _errorText = _humanize(error);
    // 录音链路断了就别装作还在录：停设备、收会话，让用户能重开一次。
    unawaited(stop());
  }

  void _enqueueAudio(Float32List chunk) {
    if (_stage != LiveStage.recording) return;
    _audioSamples += chunk.length;
    if ((_pendingSamples + chunk.length) / kSampleRate >
        maxPendingAudio.inMicroseconds / 1000000) {
      _overloadCount++;
      _errorText = '识别速度跟不上录音，音频积压超过上限，已停止录音。';
      unawaited(stop());
      return;
    }
    _pendingAudio.add(chunk);
    _pendingSamples += chunk.length;
    if (_pendingSamples > _peakPendingSamples) {
      _peakPendingSamples = _pendingSamples;
    }
    _audioPump ??= _drainAudio(_session!, _audioGeneration);
    notifyListeners();
  }

  Future<void> _drainAudio(LiveSession session, int generation) async {
    try {
      while (generation == _audioGeneration &&
          _pendingAudio.isNotEmpty &&
          !_workerUnhealthy) {
        final Float32List chunk = _pendingAudio.removeFirst();
        final Stopwatch watch = Stopwatch()..start();
        try {
          await session.accept(chunk).timeout(operationTimeout);
        } finally {
          watch.stop();
          if (generation == _audioGeneration &&
              watch.elapsed > _maxAcceptLatency) {
            _maxAcceptLatency = watch.elapsed;
          }
        }
        if (generation != _audioGeneration) return;
        _pendingSamples -= chunk.length;
        notifyListeners();
      }
    } on Object catch (error) {
      if (generation == _audioGeneration) _onStreamError(error);
    } finally {
      if (generation == _audioGeneration) _audioPump = null;
    }
  }

  /// 每个外部异步步骤有独立上限；失败后仍继续退订、回收与释放租约。
  Future<void> _teardown() =>
      _tearingDown ??= _performTeardown().whenComplete(() {
        _tearingDown = null;
      });

  Future<void> _performTeardown() async {
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action().timeout(operationTimeout);
      } on Object catch (error) {
        _workerUnhealthy = true;
        _errorText ??= _humanize(error);
      }
    }

    try {
      await attempt(_mic.stop);
      final StreamSubscription<Float32List>? audio = _audio;
      _audio = null;
      if (audio != null) await attempt(audio.cancel);
      final Future<void>? pump = _audioPump;
      if (pump != null) await attempt(() => pump);
      _audioGeneration++;
      _audioPump = null;
      final LiveSession? session = _session;
      _session = null;
      if (session != null) await attempt(session.finish);
      final StreamSubscription<Segment>? segments = _segments;
      _segments = null;
      if (segments != null) await attempt(segments.cancel);
    } finally {
      _audioGeneration++;
      _audioPump = null;
      _pendingAudio.clear();
      _pendingSamples = 0;
      final Transcriber? worker = _activeWorker;
      _activeWorker = null;
      try {
        if (worker != null) {
          if (_workerUnhealthy) {
            await attempt(
              () => discardWorker?.call(worker) ?? worker.dispose(),
            );
          } else {
            releaseWorker?.call(worker);
          }
        }
      } finally {
        _releaseTaskLease();
      }
    }
  }

  void _teardownWorker() {
    final Transcriber? worker = _activeWorker;
    _activeWorker = null;
    if (worker != null) {
      releaseWorker?.call(worker);
    }
  }

  void _releaseTaskLease() {
    final TranscriptionTaskLease? lease = _taskLease;
    _taskLease = null;
    lease?.release();
  }

  String _humanize(Object error) {
    final String raw = switch (error) {
      MicrophoneException(message: final String m) => m,
      StateError(message: final String m) => m,
      _ => '$error',
    };
    return raw.replaceFirst(RegExp(r'^(Bad state: |Exception: )+'), '');
  }

  /// 显式收尾。`dispose()` 是同步的，测试与退出流程用这个。
  Future<void> shutdown() async {
    _startGeneration++;
    final bool wasActive = _stage != LiveStage.idle;
    if (_stage == LiveStage.starting) _workerUnhealthy = true;
    await _teardown();
    _releaseTaskLease();
    _translationGeneration++;
    await _awaitTranslationQueue();
    _closeTranslationProvider();
    if (wasActive) {
      _performanceWatch = null;
      _audioSamples = 0;
      _performanceReport = null;
    }
    _stage = LiveStage.idle;
  }

  Future<TranslationProvider?> _resolveTranslationProvider(
    TranslationProviderResolver resolver,
  ) async {
    if (_translationProviderResolved) {
      final Object? error = _translationProviderError;
      final StackTrace? stack = _translationProviderErrorStack;
      if (error != null && stack != null) {
        Error.throwWithStackTrace(error, stack);
      }
      return _translationProvider;
    }
    _translationProviderResolved = true;
    try {
      _translationProvider = await resolver();
      return _translationProvider;
    } on Object catch (error, stack) {
      _translationProviderError = error;
      _translationProviderErrorStack = stack;
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _awaitTranslationQueue() async {
    final Future<void>? pending = _translationQueue;
    _translationQueue = null;
    if (pending != null) {
      try {
        await pending.timeout(operationTimeout);
      } on Object catch (error) {
        _errorText ??= _humanize(error);
      }
    }
  }

  void _resetTranslationProvider() {
    _translationProvider = null;
    _translationProviderError = null;
    _translationProviderErrorStack = null;
    _translationProviderResolved = false;
  }

  void _closeTranslationProvider() {
    final TranslationProvider? provider = _translationProvider;
    if (provider is ClosableTranslationProvider) provider.close();
    _resetTranslationProvider();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
