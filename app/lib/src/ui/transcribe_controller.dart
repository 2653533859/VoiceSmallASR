/// 主界面的状态机：模型准备 → 选文件 → 解码 → 识别 → 导出。
///
/// 界面层只读这里的字段、只调这里的方法，不直接碰引擎、解码器与 isolate。
/// 所有外部依赖都能替换（解码器、模型目录、isolate 内的转写器工厂），
/// 因此整条链路可以在 `flutter test` 里跑通而不加载任何原生库。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/speaker_diarization.dart';
import 'package:vsasr_app/src/asr/speaker_diarization_model_manager.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';
import 'package:vsasr_app/src/asr/transcription_worker.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/diagnostics/performance_report.dart';
import 'package:vsasr_app/src/project/project_file.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';

/// 当前正在做什么。
enum JobStage {
  /// 空闲：没有任务在跑。
  idle,

  /// 正在检查模型是否就绪。
  checkingModel,

  /// 正在下载/解压模型，或正在加载模型到内存。
  preparingModel,

  /// 正在解码音频（wav 纯 Dart / 其余走原生）。
  decoding,

  /// 正在识别。
  transcribing,

  /// 正在翻译当前识别结果。
  translating,

  /// 正在进行离线说话人分离并把标签映射到字幕。
  diarizing,

  /// 正在删除或刷新模型缓存。
  managingModel,
}

typedef VideoTranscriptionUpdate = void Function(TranscriptionResult result);

/// 主界面状态。
class TranscribeController extends ChangeNotifier {
  TranscribeController({
    AudioDecoder? decoder,
    ModelManager? models,
    this.launch = launchWorkerIsolate,
    AsrConfig? config,
    bool offlineMode = false,
    SpeakerDiarizationModelManager? speakerModels,
    SpeakerDiarizationRunner? diarize,
  }) : _decoder = decoder ?? const PlatformAudioDecoder(),
       _models = models ?? ModelManager(),
       _speakerModels = speakerModels ?? SpeakerDiarizationModelManager(),
       _diarize = diarize ?? runOfflineSpeakerDiarization,
       _config = config ?? AsrConfig(),
       _offlineMode = false {
    _offlineMode = offlineMode;
  }

  final AudioDecoder _decoder;
  final ModelManager _models;
  final SpeakerDiarizationModelManager _speakerModels;
  final SpeakerDiarizationRunner _diarize;

  /// 怎么起转写器。默认后台 isolate；测试可注入进程内替身。
  final TranscriberLauncher launch;

  AsrConfig _config;
  bool _offlineMode;
  Transcriber? _worker;

  /// 正在关闭的旧 worker（切语言时）。新的必须等它关完再起，
  /// 否则两份 240 MB 模型会同时驻留内存。
  Future<void>? _closing;
  bool _disposed = false;

  JobStage _stage = JobStage.idle;
  bool _modelReady = false;
  int _modelBytes = 0;
  String _statusText = '';
  double? _progress;
  String? _errorText;
  String? _filePath;
  TranscriptionResult? _result;
  Duration? _elapsed;
  PerformanceReport? _performanceReport;
  int _projectRevision = 0;
  int _cancelGeneration = 0;

  /// 当前阶段。
  JobStage get stage => _stage;

  /// 模型是否已在本地就绪。
  bool get modelReady => _modelReady;

  /// 模型目录当前占用的磁盘空间。
  int get modelBytes => _modelBytes;

  /// 是否禁止自动联网下载模型。
  bool get offlineMode => _offlineMode;

  /// 面向用户的一行状态说明（下载进度、识别进度等）。
  String get statusText => _statusText;

  /// 0~1 的进度；为 null 表示进度未知（应显示不确定进度条）。
  double? get progress => _progress;

  /// 最近一次错误，已是可直接展示的中文文案。
  String? get errorText => _errorText;

  /// 当前音频文件路径。
  String? get filePath => _filePath;

  /// 最近一次识别结果。
  TranscriptionResult? get result => _result;

  /// 当前项目快照的递增版本。首页用它区分识别进度通知与需要自动保存的变更。
  int get projectRevision => _projectRevision;

  /// 当前结果的可持久化项目快照。
  VsasrProject get projectSnapshot {
    final TranscriptionResult? current = _result;
    if (current == null) throw StateError('还没有可保存的识别结果');
    return VsasrProject(mediaPath: _filePath, config: _config, result: current);
  }

  /// 从项目文件恢复当前字幕和识别配置；媒体文件仍由调用方按路径重新打开。
  Future<void> loadProject(VsasrProject project) async {
    if (busy) throw StateError('识别进行中，暂时不能打开项目');
    // 配置切换和结果替换必须作为一个快照提交，避免首页在旧结果上先自动保存
    // 新配置，随后才收到本项目的字幕结果。
    await applyConfig(project.config, markProjectChange: false);
    _filePath = project.mediaPath;
    _result = project.result;
    _elapsed = null;
    _performanceReport = null;
    _progress = null;
    _errorText = null;
    _statusText = '项目已打开：${project.result.length} 段字幕';
    _markProjectChanged();
    notifyListeners();
  }

  /// 只替换项目引用的媒体文件，不重新识别已有字幕。
  void relocateMedia(String path) {
    if (busy) throw StateError('识别进行中，暂时不能更换媒体文件');
    final String value = path.trim();
    if (value.isEmpty) throw ArgumentError('媒体文件路径不能为空');
    _filePath = value;
    _performanceReport = null;
    _errorText = null;
    _statusText = '媒体文件已重新定位';
    _markProjectChanged();
    notifyListeners();
  }

  /// 接收外部导入的带时间轴字幕；可选地把当前项目绑定到指定媒体。
  void applyImportedResult(TranscriptionResult imported, {String? mediaPath}) {
    if (busy) throw StateError('识别进行中，暂时不能导入字幕');
    ensureValidSubtitleTimeline(imported.segments, duration: imported.duration);
    if (mediaPath != null) {
      final String value = mediaPath.trim();
      if (value.isEmpty) throw ArgumentError('媒体文件路径不能为空');
      _filePath = value;
    }
    _result = imported;
    _elapsed = null;
    _performanceReport = null;
    _progress = null;
    _errorText = null;
    _statusText = '字幕已导入：${imported.length} 段';
    _markProjectChanged();
    notifyListeners();
  }

  /// 接收字幕校对页保存后的结果。
  ///
  /// 校对页只在空闲时打开；这里仍做一次时间轴校验，避免其他调用方绕过编辑器
  /// 把重叠或倒序字幕写回主界面。
  void applyEditedResult(TranscriptionResult edited) {
    if (busy) throw StateError('识别进行中，暂时不能应用字幕修改');
    ensureValidSubtitleTimeline(edited.segments, duration: edited.duration);
    _result = edited;
    _statusText = '字幕已更新';
    _errorText = null;
    _markProjectChanged();
    notifyListeners();
  }

  /// 最近一次识别耗时。
  Duration? get elapsed => _elapsed;

  /// 最近一次成功文件转写的详细性能诊断；导入/打开项目不会伪造该报告。
  PerformanceReport? get performanceReport => _performanceReport;

  /// 识别语言（`auto`/`zh`/`en`/`ja`/`ko`/`yue`）。
  String get language => _config.language;

  /// 当前完整识别配置，设置页用它初始化表单。
  AsrConfig get config => _config;

  /// 有任务在跑时界面应禁用按钮。
  bool get busy => _stage != JobStage.idle;

  /// 界面已经销毁后仍会有异步任务收尾（下载几十秒、识别几分钟），
  /// 那时通知监听者会抛 "used after being disposed"，因此统一在这里拦掉。
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// 检查模型是否就绪。启动时调一次。
  Future<void> refreshModel() async {
    _stage = JobStage.checkingModel;
    _errorText = null;
    notifyListeners();
    try {
      _modelReady = await _models.isReady();
      _modelBytes = 0;
      _statusText = _modelReady ? '模型就绪' : '首次使用需要下载模型';
      if (_modelReady) unawaited(_updateModelBytes());
    } on Object catch (error) {
      _modelReady = false;
      _modelBytes = 0;
      _errorText = '检查模型失败：$error';
    } finally {
      _stage = JobStage.idle;
      notifyListeners();
    }
  }

  /// 准备模型与识别 isolate：缺模型就下载，然后把模型加载进 isolate。
  ///
  /// 重复调用是安全的（已就绪时直接返回）。
  Future<void> prepare({bool? allowDownload}) async {
    if (_worker != null || busy) return;
    final int generation = _cancelGeneration;
    _stage = JobStage.preparingModel;
    _errorText = null;
    _progress = null;
    _statusText = _modelReady ? '正在加载模型…' : '正在准备模型…';
    notifyListeners();
    try {
      // 切语言时旧 isolate 可能还在关。抢在它前面加载新模型，内存里会同时躺着
      // 两份 240 MB 的权重，手机上直接爆。
      await _closing;
      final Transcriber worker = await launch(
        config: _config,
        allowDownload: allowDownload ?? !_offlineMode,
        onModelProgress: _onModelProgress,
      );
      // 模型下载/加载要几十秒，这期间界面可能已经被销毁。此时 dispose()
      // 看到的 _worker 还是 null，什么都没关；必须由这里收掉迟到的 worker，
      // 否则 isolate 与它加载的 240 MB 模型会漏到进程结束。
      if (_disposed || generation != _cancelGeneration) {
        await worker.dispose();
        return;
      }
      _worker = worker;
      _modelReady = true;
      unawaited(_updateModelBytes());
      _statusText = '模型就绪';
      _progress = null;
    } on Object catch (error) {
      _errorText = _humanize(error);
      _statusText = '模型准备失败';
      _progress = null;
    } finally {
      _stage = JobStage.idle;
      notifyListeners();
    }
  }

  /// 拿到已加载模型的转写器；还没准备好就先准备一次。
  ///
  /// 失败时返回 null，原因在 [errorText] 里 —— 实时字幕页共用同一个 worker，
  /// 模型只加载一次（240 MB，加载两份在手机上直接爆内存）。
  Future<Transcriber?> ensureWorker() async {
    if (_worker == null) await prepare();
    return _worker;
  }

  /// 设置页的显式下载操作，即使开启离线模式也允许用户主动触发。
  Future<void> downloadModel() => prepare(allowDownload: true);

  /// 切换自动下载策略。已加载的模型继续可用，下一次自动准备时生效。
  void setOfflineMode(bool enabled) {
    if (_offlineMode == enabled || busy) return;
    _offlineMode = enabled;
    notifyListeners();
  }

  /// 关闭已加载 worker 后删除模型缓存。
  Future<void> deleteModel() async {
    if (busy) return;
    _stage = JobStage.managingModel;
    _errorText = null;
    _statusText = '正在删除模型…';
    notifyListeners();
    try {
      await _closing;
      final Transcriber? worker = _worker;
      _worker = null;
      await worker?.dispose();
      await _models.deleteAll();
      _modelReady = false;
      _modelBytes = 0;
      _statusText = '模型已删除';
    } on Object catch (error) {
      _errorText = _humanize(error);
      _statusText = '删除模型失败';
    } finally {
      _stage = JobStage.idle;
      notifyListeners();
    }
  }

  void _onModelProgress(String stage, int done, int total) {
    _statusText = stage;
    _progress = total > 0 ? done / total : null;
    notifyListeners();
  }

  Future<void> _updateModelBytes() async {
    try {
      final int bytes = await _models.usedBytes();
      if (_disposed || !_modelReady) return;
      _modelBytes = bytes;
      notifyListeners();
    } on Object {
      // 占用空间只是展示信息，统计失败不应让已就绪的模型变成不可用。
    }
  }

  /// 应用完整识别配置。
  ///
  /// 识别器创建时会固定语言、线程数、ITN 与 VAD 参数，因此已有 worker
  /// 必须安全关闭，下一次识别/录音再按新配置加载。正在做文件任务时不改配置，
  /// 避免一条音频前后使用两套模型参数。
  Future<void> applyConfig(
    AsrConfig config, {
    bool markProjectChange = true,
  }) async {
    if (busy || _sameConfig(_config, config)) return;
    _config = config;
    _performanceReport = null;
    if (markProjectChange && _result != null) _markProjectChanged();
    notifyListeners();
    final Transcriber? old = _worker;
    if (old == null) return;
    _worker = null;
    // 记下这个 Future：期间 prepare() 会先 await 它，不会又起一个 isolate。
    final Future<void> closing = old.dispose();
    _closing = closing;
    try {
      await closing;
    } finally {
      if (identical(_closing, closing)) _closing = null;
    }
  }

  /// 改识别语言。已加载的 isolate 会被重启（语言在建识别器时定死）。
  Future<void> setLanguage(String language) =>
      applyConfig(_config.copyWith(language: language));

  /// 解码并识别一个文件。这是主流程的入口。
  Future<void> transcribeFile(String path) async {
    if (busy) return;
    final int generation = _cancelGeneration;
    _filePath = path;
    _result = null;
    _elapsed = null;
    _performanceReport = null;
    _errorText = null;
    notifyListeners();

    Duration? modelPreparationElapsed;
    if (_worker == null) {
      final Stopwatch preparationWatch = Stopwatch()..start();
      await prepare();
      modelPreparationElapsed = preparationWatch.elapsed;
      if (generation != _cancelGeneration) return;
      if (_worker == null) return; // prepare 已经把错误写进 _errorText
    }

    final Stopwatch watch = Stopwatch()..start();
    try {
      _stage = JobStage.decoding;
      _statusText = '正在解码音频…';
      _progress = null;
      notifyListeners();
      final Stopwatch decodeWatch = Stopwatch()..start();
      // 解码留在主 isolate：平台通道只在 root isolate 可用，
      // 而原生侧本身已经在后台线程解码，不会卡界面。
      final Float32List samples = await _decoder.decodeFile(path);
      final Duration decodeElapsed = decodeWatch.elapsed;
      if (generation != _cancelGeneration) return;

      _stage = JobStage.transcribing;
      _statusText = '正在识别…';
      _progress = 0;
      notifyListeners();
      final Stopwatch transcriptionWatch = Stopwatch()..start();
      final TranscriptionResult result = await _worker!.transcribe(
        samples,
        onProgress: (int done, int total) {
          _progress = total > 0 ? done / total : null;
          _statusText = '正在识别… ${((_progress ?? 0) * 100).round()}%';
          notifyListeners();
        },
      );
      final Duration transcriptionElapsed = transcriptionWatch.elapsed;
      if (generation != _cancelGeneration) return;
      _result = result;
      _elapsed = watch.elapsed;
      _performanceReport = PerformanceReport(
        generatedAt: DateTime.now(),
        fileName: p.basename(path),
        platform: Platform.operatingSystem,
        language: _config.language,
        audioDuration: result.duration,
        sampleCount: samples.length,
        segmentCount: result.length,
        elapsed: _elapsed!,
        decodeElapsed: decodeElapsed,
        transcriptionElapsed: transcriptionElapsed,
        modelPreparationElapsed: modelPreparationElapsed,
        modelBytes: _modelBytes > 0 ? _modelBytes : null,
        numThreads: _config.numThreads,
        useItn: _config.useItn,
        partialInterval: _config.partialInterval,
        vadThreshold: _config.vad.threshold,
        minSilenceDuration: _config.vad.minSilenceDuration,
        minSpeechDuration: _config.vad.minSpeechDuration,
        maxSpeechDuration: _config.vad.maxSpeechDuration,
      );
      _statusText = '识别完成：${result.length} 段';
      _progress = 1;
      _markProjectChanged();
    } on AudioDecodeException catch (error) {
      if (generation != _cancelGeneration) return;
      _errorText = error.message;
      _statusText = '解码失败';
    } on Object catch (error) {
      if (generation != _cancelGeneration) return;
      _errorText = _humanize(error);
      _statusText = '识别失败';
    } finally {
      _stage = JobStage.idle;
      notifyListeners();
    }
  }

  /// 以流式会话转写视频音轨，逐段回报字幕，但不覆盖当前项目结果。
  ///
  /// 播放列表预处理复用同一个 worker，避免额外加载一份约 240 MB 的模型。
  Future<TranscriptionResult> transcribeVideoStream(
    String path, {
    VideoTranscriptionUpdate? onUpdate,
  }) async {
    if (busy) throw StateError('当前正在处理另一个文件');
    final int generation = _cancelGeneration;
    final Transcriber? worker = await ensureWorker();
    if (worker == null) {
      throw StateError(_errorText ?? '识别模型未就绪');
    }
    if (_disposed || generation != _cancelGeneration) {
      throw StateError('视频字幕转写已取消');
    }

    LiveSession? session;
    StreamSubscription<Segment>? subscription;
    try {
      _stage = JobStage.decoding;
      _errorText = null;
      _progress = null;
      _statusText = '正在解码视频音轨…';
      notifyListeners();
      _stage = JobStage.transcribing;
      _progress = 0;
      _statusText = '正在实时转写视频字幕…';
      notifyListeners();
      session = await worker.startLive();
      final List<Segment> finals = <Segment>[];
      Segment? partial;
      var decodedSamples = 0;
      final Completer<void> completed = Completer<void>();
      subscription = session.segments.listen(
        (Segment segment) {
          if (_disposed || generation != _cancelGeneration) return;
          if (segment.isFinal) {
            finals.add(segment);
            partial = null;
          } else {
            partial = segment;
          }
          onUpdate?.call(
            TranscriptionResult(
              segments: <Segment>[...finals, ?partial],
              duration: decodedSamples / kSampleRate,
              language: _config.language,
            ),
          );
        },
        onError: (Object error, StackTrace stack) {
          if (!completed.isCompleted) completed.completeError(error, stack);
        },
        onDone: () {
          if (!completed.isCompleted) completed.complete();
        },
      );
      await for (final DecodedAudioChunk decoded in _videoAudioChunks(path)) {
        if (_disposed || generation != _cancelGeneration) {
          throw StateError('视频字幕转写已取消');
        }
        decodedSamples += decoded.samples.length;
        session.accept(decoded.samples);
        _progress = null;
        _statusText = '正在实时转写视频字幕… ${(decodedSamples / kSampleRate).round()} 秒';
        notifyListeners();
      }
      await session.finish();
      session = null;
      await completed.future;
      final TranscriptionResult result = TranscriptionResult(
        segments: List<Segment>.unmodifiable(finals),
        duration: decodedSamples / kSampleRate,
        language: _config.language,
      );
      onUpdate?.call(result);
      _progress = 1;
      _statusText = '视频字幕转写完成：${result.length} 段';
      return result;
    } on AudioDecodeException catch (error) {
      _errorText = error.message;
      _statusText = '视频音轨解码失败';
      rethrow;
    } on Object catch (error) {
      _errorText = _humanize(error);
      _statusText = '视频字幕转写失败';
      rethrow;
    } finally {
      try {
        await session?.finish();
      } on Object {
        // 主错误由上层处理；这里只保证实时会话尽量释放。
      }
      await subscription?.cancel();
      _stage = JobStage.idle;
      notifyListeners();
    }
  }

  Stream<DecodedAudioChunk> _videoAudioChunks(String path) async* {
    final AudioDecoder decoder = _decoder;
    if (decoder is ChunkedAudioDecoder) {
      yield* (decoder as ChunkedAudioDecoder).decodeFileChunks(path);
      return;
    }
    final Float32List samples = await decoder.decodeFile(path);
    const int chunkSize = kSampleRate * 2;
    for (int offset = 0; offset < samples.length; offset += chunkSize) {
      final int end = (offset + chunkSize).clamp(0, samples.length).toInt();
      yield DecodedAudioChunk(
        Float32List.sublistView(samples, offset, end),
        isLast: end == samples.length,
      );
    }
  }

  /// 为当前识别结果自动标注说话人。
  ///
  /// 说话人分离需要重新读取当前媒体文件，因此导入的独立字幕只有在项目
  /// 已绑定媒体路径时才能使用。分离结果只写回字幕段的 speaker 字段，
  /// 不会覆盖文字、时间戳或已有译文。
  Future<void> diarizeCurrentResult({
    int numClusters = -1,
    double threshold = 0.9,
  }) async {
    if (busy) return;
    final TranscriptionResult? source = _result;
    final String? path = _filePath;
    if (source == null) throw StateError('还没有可标注的识别结果');
    if (path == null || path.trim().isEmpty) {
      throw StateError('自动说话人分离需要绑定原媒体文件');
    }
    final SpeakerDiarizationOptions options = SpeakerDiarizationOptions(
      numClusters: numClusters,
      threshold: threshold,
    );
    options.validate();

    final int generation = _cancelGeneration;
    _stage = JobStage.diarizing;
    _errorText = null;
    _progress = null;
    _statusText = '正在准备说话人模型…';
    notifyListeners();
    try {
      final SpeakerDiarizationModelPaths paths = await _speakerModels.ensure(
        allowDownload: !_offlineMode,
        progress: _onModelProgress,
      );
      if (_disposed || generation != _cancelGeneration) return;

      _statusText = '正在解码音频…';
      _progress = null;
      notifyListeners();
      final Float32List samples = await _decoder.decodeFile(path);
      if (_disposed || generation != _cancelGeneration) return;

      _statusText = '正在分析说话人…';
      _progress = null;
      notifyListeners();
      final List<SpeakerDiarizationSpan> spans = await _diarize(
        samples,
        paths,
        options,
      );
      if (_disposed || generation != _cancelGeneration) return;

      final TranscriptionResult labeled = applySpeakerDiarization(
        source,
        spans,
      );
      _result = labeled;
      final Set<String> speakers = labeled.segments
          .map((Segment segment) => segment.speaker)
          .whereType<String>()
          .toSet();
      _statusText = '说话人标注完成：${speakers.length} 位';
      _progress = 1;
      _markProjectChanged();
    } on AudioDecodeException catch (error) {
      if (_disposed || generation != _cancelGeneration) return;
      _errorText = error.message;
      _statusText = '解码失败';
      _progress = null;
    } on Object catch (error) {
      if (_disposed || generation != _cancelGeneration) return;
      _errorText = _humanize(error);
      _statusText = '说话人标注失败';
      _progress = null;
    } finally {
      _stage = JobStage.idle;
      notifyListeners();
    }
  }

  /// 翻译当前识别结果，并在所有批次成功后一次性写回译文。
  ///
  /// [provider] 由界面或调用方创建，API Key 的读取和 provider 生命周期不放进
  /// 状态机。翻译失败时保留原结果，避免把半成品译文显示或导出出去。
  Future<void> translateCurrentResult(
    TranslationProvider provider, {
    String targetLanguage = 'ZH',
    int batchSize = 20,
    int maxRetries = 2,
    Duration retryDelay = const Duration(milliseconds: 250),
  }) async {
    if (busy) return;
    final int generation = _cancelGeneration;
    final TranscriptionResult? source = _result;
    if (source == null) throw StateError('还没有可翻译的识别结果');
    _stage = JobStage.translating;
    _errorText = null;
    _progress = 0;
    _statusText = '正在翻译…';
    notifyListeners();
    try {
      final TranscriptionResult translated = await translateResult(
        source,
        provider,
        to: targetLanguage,
        batchSize: batchSize,
        maxRetries: maxRetries,
        retryDelay: retryDelay,
        onProgress: (int done, int total) {
          _progress = total > 0 ? done / total : null;
          _statusText = total > 0
              ? '正在翻译… ${(done / total * 100).round()}%'
              : '正在翻译…';
          notifyListeners();
        },
      );
      if (_disposed || generation != _cancelGeneration) return;
      _result = translated;
      _progress = 1;
      _statusText = '翻译完成：${translated.length} 段';
      _markProjectChanged();
    } on Object catch (error) {
      if (_disposed || generation != _cancelGeneration) return;
      _errorText = _humanize(error);
      _progress = null;
      _statusText = '翻译失败';
    } finally {
      _stage = JobStage.idle;
      notifyListeners();
    }
  }

  /// 把结果渲染成指定格式的文本（`srt`/`vtt`/`json`/`txt`）。
  ///
  /// 只负责生成内容，落盘交给界面层 —— 三端的保存对话框差异很大
  /// （macOS 走 sandbox 授权、Android 走 SAF），不该混进状态机里。
  String renderResult(String format) {
    final TranscriptionResult? result = _result;
    if (result == null) throw StateError('还没有可导出的识别结果');
    return renderSubtitles(result, format);
  }

  /// 把异常转成能直接给用户看的一行中文。
  String _humanize(Object error) {
    final String raw = error is StateError ? error.message : '$error';
    // isolate 边界上异常被压成字符串，Dart 会带上 "Bad state: " 前缀。
    return raw.replaceFirst(RegExp(r'^(Bad state: |Exception: )+'), '');
  }

  bool _sameConfig(AsrConfig a, AsrConfig b) {
    final VadConfig av = a.vad;
    final VadConfig bv = b.vad;
    return a.language == b.language &&
        a.useItn == b.useItn &&
        a.numThreads == b.numThreads &&
        a.partialInterval == b.partialInterval &&
        av.threshold == bv.threshold &&
        av.minSilenceDuration == bv.minSilenceDuration &&
        av.minSpeechDuration == bv.minSpeechDuration &&
        av.maxSpeechDuration == bv.maxSpeechDuration &&
        av.windowSize == bv.windowSize;
  }

  void _markProjectChanged() {
    _projectRevision++;
  }

  /// 关闭识别 isolate。`dispose()` 不能 await，测试与显式收尾用这个。
  Future<void> shutdown() async {
    _cancelGeneration++;
    final Transcriber? worker = _worker;
    _worker = null;
    await worker?.dispose();
  }

  /// 取消当前准备、解码、识别、翻译或说话人标注操作，并阻止迟到的异步结果写回。
  ///
  /// 翻译和说话人标注都是对已有结果的后处理，取消时必须保留原字幕；
  /// 只有新转写阶段才清空尚未完成的结果。
  Future<void> cancelCurrentTask() async {
    if (!busy) return;
    _cancelGeneration++;
    if (_stage == JobStage.decoding || _stage == JobStage.transcribing) {
      _result = null;
    }
    _progress = null;
    _errorText = null;
    _statusText = '处理已取消';
    final Transcriber? worker = _worker;
    _worker = null;
    notifyListeners();
    await worker?.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    // ChangeNotifier.dispose 是同步的，isolate 的关闭只能放后台跑。
    unawaited(shutdown());
    super.dispose();
  }
}
