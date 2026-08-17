/// 实时字幕的状态机：麦克风 → 识别 isolate → 临时/定稿两类段。
///
/// 与 [TranscribeController] 的分工：那边管文件转写，这边管麦克风；
/// 两边**共用同一个识别 worker**（模型只加载一次），因此本类不自己起 isolate，
/// 而是通过 [provideWorker] 借用。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';
import 'package:vsasr_app/src/audio/microphone.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';

/// 借用识别器。返回 null 表示模型没准备好（原因由提供方自己展示）。
typedef WorkerProvider = Future<Transcriber?> Function();

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
    required this.languageOf,
    this.provideTranslationProvider,
    this.translationTargetLanguage = 'zh-CN',
    AudioSource? mic,
  }) : _mic = mic ?? MicrophoneSource();

  final WorkerProvider provideWorker;
  final LanguageOf languageOf;
  final TranslationProviderResolver? provideTranslationProvider;
  final String translationTargetLanguage;
  final AudioSource _mic;

  final List<Segment> _finals = <Segment>[];
  Segment? _partial;
  LiveSession? _session;
  StreamSubscription<Segment>? _segments;
  StreamSubscription<Float32List>? _audio;
  Future<void>? _translationQueue;
  int _translationGeneration = 0;
  TranslationProvider? _translationProvider;
  Object? _translationProviderError;
  StackTrace? _translationProviderErrorStack;
  bool _translationProviderResolved = false;

  LiveStage _stage = LiveStage.idle;
  String? _errorText;
  bool _disposed = false;
  bool _translationEnabled = false;

  LiveStage get stage => _stage;

  bool get recording => _stage == LiveStage.recording;

  /// 忙碌时界面应禁用「开始/停止」以外的操作。
  bool get busy => _stage != LiveStage.idle;

  /// 已定稿的句子，按时间顺序。
  List<Segment> get finals => List<Segment>.unmodifiable(_finals);

  /// 当前这句的临时结果；下一次刷新会替换它，定稿后清空。
  Segment? get partial => _partial;

  String? get errorText => _errorText;

  /// 是否在定稿字幕后自动请求第三方翻译 API。
  bool get translationEnabled => _translationEnabled;

  bool get hasResult => _finals.isNotEmpty;

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
    _resetTranslationProvider();
    _stage = LiveStage.starting;
    _errorText = null;
    notifyListeners();
    try {
      final Transcriber? worker = await provideWorker();
      if (worker == null) throw StateError('模型未就绪，先在「文件转写」页把模型下载好');
      if (_disposed) return;

      final LiveSession session = await worker.startLive();
      _session = session;
      _segments = session.segments.listen(_onSegment, onError: _onStreamError);

      // 先开会话再开设备：反过来的话，最早的几块音频会没人接。
      final Stream<Float32List> audio = await _mic.start();
      _audio = audio.listen(
        (Float32List chunk) => _session?.accept(chunk),
        onError: _onStreamError,
      );
      _stage = LiveStage.recording;
    } on Object catch (error) {
      _errorText = _humanize(error);
      await _teardown();
      _translationGeneration++;
      await _awaitTranslationQueue();
      _closeTranslationProvider();
      _stage = LiveStage.idle;
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
    // 使尚未开始的排队请求失效；当前正在进行的请求最多只需等待一次超时。
    _translationGeneration++;
    await _awaitTranslationQueue();
    _closeTranslationProvider();
    _stage = LiveStage.idle;
    notifyListeners();
  }

  /// 清空已识别的内容，准备下一场。
  void clear() {
    if (busy) return;
    _finals.clear();
    _partial = null;
    _errorText = null;
    notifyListeners();
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
      } on Object catch (error) {
        if (_disposed) return;
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
    final List<String> translated = await provider.translate(
      <String>[segment.text],
      from: source,
      to: translationTargetLanguage,
    );
    if (translated.length != 1) {
      throw StateError('翻译服务返回 ${translated.length} 条结果，需要 1 条，无法安全对应实时字幕');
    }
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
    notifyListeners();
  }

  void _onStreamError(Object error) {
    _errorText = _humanize(error);
    // 录音链路断了就别装作还在录：停设备、收会话，让用户能重开一次。
    unawaited(stop());
  }

  /// 停设备 → 收会话 → 退订。顺序不能反：先停采集才不会有块喂给已关的会话。
  Future<void> _teardown() async {
    try {
      await _mic.stop();
    } on Object {
      // 设备本来就没开起来，忽略
    }
    await _audio?.cancel();
    _audio = null;
    await _session?.finish();
    _session = null;
    await _segments?.cancel();
    _segments = null;
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
    await _teardown();
    _translationGeneration++;
    await _awaitTranslationQueue();
    _closeTranslationProvider();
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
    if (pending != null) await pending;
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
