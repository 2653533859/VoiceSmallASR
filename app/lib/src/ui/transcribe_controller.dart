/// 主界面的状态机：模型准备 → 选文件 → 解码 → 识别 → 导出。
///
/// 界面层只读这里的字段、只调这里的方法，不直接碰引擎、解码器与 isolate。
/// 所有外部依赖都能替换（解码器、模型目录、isolate 内的转写器工厂），
/// 因此整条链路可以在 `flutter test` 里跑通而不加载任何原生库。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/transcription_worker.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

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
}

/// 主界面状态。
class TranscribeController extends ChangeNotifier {
  TranscribeController({
    AudioDecoder? decoder,
    ModelManager? models,
    this.launch = launchWorkerIsolate,
    AsrConfig? config,
  }) : _decoder = decoder ?? const PlatformAudioDecoder(),
       _models = models ?? ModelManager(),
       _config = config ?? AsrConfig();

  final AudioDecoder _decoder;
  final ModelManager _models;

  /// 怎么起转写器。默认后台 isolate；测试可注入进程内替身。
  final TranscriberLauncher launch;

  AsrConfig _config;
  Transcriber? _worker;

  /// 正在关闭的旧 worker（切语言时）。新的必须等它关完再起，
  /// 否则两份 240 MB 模型会同时驻留内存。
  Future<void>? _closing;
  bool _disposed = false;

  JobStage _stage = JobStage.idle;
  bool _modelReady = false;
  String _statusText = '';
  double? _progress;
  String? _errorText;
  String? _filePath;
  TranscriptionResult? _result;
  Duration? _elapsed;

  /// 当前阶段。
  JobStage get stage => _stage;

  /// 模型是否已在本地就绪。
  bool get modelReady => _modelReady;

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

  /// 最近一次识别耗时。
  Duration? get elapsed => _elapsed;

  /// 识别语言（`auto`/`zh`/`en`/`ja`/`ko`/`yue`）。
  String get language => _config.language;

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
      _statusText = _modelReady ? '模型就绪' : '首次使用需要下载模型';
    } on Object catch (error) {
      _modelReady = false;
      _errorText = '检查模型失败：$error';
    } finally {
      _stage = JobStage.idle;
      notifyListeners();
    }
  }

  /// 准备模型与识别 isolate：缺模型就下载，然后把模型加载进 isolate。
  ///
  /// 重复调用是安全的（已就绪时直接返回）。
  Future<void> prepare({bool allowDownload = true}) async {
    if (_worker != null || busy) return;
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
        allowDownload: allowDownload,
        onModelProgress: _onModelProgress,
      );
      // 模型下载/加载要几十秒，这期间界面可能已经被销毁。此时 dispose()
      // 看到的 _worker 还是 null，什么都没关；必须由这里收掉迟到的 worker，
      // 否则 isolate 与它加载的 240 MB 模型会漏到进程结束。
      if (_disposed) {
        await worker.dispose();
        return;
      }
      _worker = worker;
      _modelReady = true;
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

  void _onModelProgress(String stage, int done, int total) {    _statusText = stage;
    _progress = total > 0 ? done / total : null;
    notifyListeners();
  }

  /// 改识别语言。已加载的 isolate 会被重启（语言是建识别器时定死的）。
  Future<void> setLanguage(String language) async {
    if (language == _config.language || busy) return;
    _config = _config.copyWith(language: language);
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

  /// 解码并识别一个文件。这是主流程的入口。
  Future<void> transcribeFile(String path) async {
    if (busy) return;
    _filePath = path;
    _result = null;
    _elapsed = null;
    _errorText = null;
    notifyListeners();

    if (_worker == null) {
      await prepare();
      if (_worker == null) return; // prepare 已经把错误写进 _errorText
    }

    final Stopwatch watch = Stopwatch()..start();
    try {
      _stage = JobStage.decoding;
      _statusText = '正在解码音频…';
      _progress = null;
      notifyListeners();
      // 解码留在主 isolate：平台通道只在 root isolate 可用，
      // 而原生侧本身已经在后台线程解码，不会卡界面。
      final Float32List samples = await _decoder.decodeFile(path);

      _stage = JobStage.transcribing;
      _statusText = '正在识别…';
      _progress = 0;
      notifyListeners();
      final TranscriptionResult result = await _worker!.transcribe(
        samples,
        onProgress: (int done, int total) {
          _progress = total > 0 ? done / total : null;
          _statusText = '正在识别… ${((_progress ?? 0) * 100).round()}%';
          notifyListeners();
        },
      );
      _result = result;
      _elapsed = watch.elapsed;
      _statusText = '识别完成：${result.length} 段';
      _progress = 1;
    } on AudioDecodeException catch (error) {
      _errorText = error.message;
      _statusText = '解码失败';
    } on Object catch (error) {
      _errorText = _humanize(error);
      _statusText = '识别失败';
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

  /// 关闭识别 isolate。`dispose()` 不能 await，测试与显式收尾用这个。
  Future<void> shutdown() async {
    final Transcriber? worker = _worker;
    _worker = null;
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
