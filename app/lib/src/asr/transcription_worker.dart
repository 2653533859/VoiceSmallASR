/// 把识别放进后台 isolate，避免长音频把界面卡住。
///
/// 为什么必须是 isolate 而不是 `await`：sherpa-onnx 的解码是**同步 FFI 调用**，
/// Dart 绑定又没有 `decodeStreams`（只能逐段解码）。在 UI isolate 上跑时，
/// `AsrEngine.transcribe` 里的 `Future.delayed(Duration.zero)` 只能让出段与段
/// 之间的间隙，单段解码期间画面照样掉帧。
///
/// 音频解码**不在**这里做：平台通道只在 root isolate 上可用，所以整条链是
/// 主 isolate 解码音频（原生侧本身已在后台线程跑）→ 把 `Float32List`
/// 交给本 worker 识别 → 收回纯数据 `TranscriptionResult`。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show RootIsolateToken;

import 'package:flutter/services.dart' show BackgroundIsolateBinaryMessenger;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';

/// 在 isolate 内构造转写器的工厂。
///
/// 必须是**顶层函数或静态方法** —— 捕获了状态的闭包不能跨 isolate 传递。
/// 测试传一个替身工厂即可完全绕开原生库。
typedef TranscriberFactory = Future<Transcriber> Function(WorkerSetup setup);

/// 默认工厂：真正加载模型的那个。
Future<Transcriber> createAsrEngine(WorkerSetup setup) => AsrEngine.create(
  config: setup.config,
  allowDownload: setup.allowDownload,
  progress: setup.reportModelProgress,
);

/// 传给工厂的启动参数。只在 isolate 内部使用。
class WorkerSetup {
  // 位置参数而非命名参数：命名参数不允许以下划线开头，而 `_events`
  // 不该出现在公开 API 里。
  const WorkerSetup._(this.config, this.allowDownload, this._events);

  final AsrConfig config;
  final bool allowDownload;
  final SendPort _events;

  /// 把模型下载/解压进度报回主 isolate。
  void reportModelProgress(String stage, int done, int total) {
    _events.send(_ModelProgressEvent(stage, done, total));
  }
}

/// 启动一个转写器。默认实现 [launchWorkerIsolate] 起后台 isolate；
/// 界面层的测试可以注入进程内替身，从而不牵扯 isolate 与原生库。
typedef TranscriberLauncher =
    Future<Transcriber> Function({
      required AsrConfig config,
      required bool allowDownload,
      required ModelProgress onModelProgress,
    });

/// 默认启动方式：后台 isolate + 真正的 [AsrEngine]。
Future<Transcriber> launchWorkerIsolate({
  required AsrConfig config,
  required bool allowDownload,
  required ModelProgress onModelProgress,
}) => TranscriptionWorker.start(
  config: config,
  allowDownload: allowDownload,
  onModelProgress: onModelProgress,
);

/// 后台识别 worker：一个常驻 isolate，模型只加载一次，请求串行处理。
///
/// 用完必须 [dispose]，否则 isolate 与它持有的原生资源都不会释放。
class TranscriptionWorker implements Transcriber {
  TranscriptionWorker._(
    this._isolate,
    this._commands,
    this._events,
    this._subscription,
    this._pending,
    this._exited,
    this._live,
  );

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;
  final StreamSubscription<Object?> _subscription;
  final Map<int, _Pending> _pending;
  final Completer<void> _exited;
  final _LiveHub _live;

  int _nextId = 0;
  bool _closed = false;

  /// 启动 worker：spawn isolate → 加载模型 → 等它报告就绪。
  ///
  /// 模型缺失时按 [allowDownload] 决定是下载还是立刻失败，下载进度经
  /// [onModelProgress] 回报（`stage` 与 [ModelManager] 的一致）。
  /// 加载失败时本方法抛异常，且不会留下野 isolate。
  static Future<TranscriptionWorker> start({
    AsrConfig? config,
    bool allowDownload = true,
    TranscriberFactory factory = createAsrEngine,
    ModelProgress? onModelProgress,
  }) async {
    final ReceivePort events = ReceivePort();
    final Completer<SendPort> ready = Completer<SendPort>();
    final Completer<void> exited = Completer<void>();
    final Map<int, _Pending> pending = <int, _Pending>{};
    final _LiveHub live = _LiveHub();

    final StreamSubscription<Object?> subscription = events.listen((Object? message) {
      _dispatch(message, ready, exited, pending, live, onModelProgress);
    });

    Isolate isolate;
    try {
      isolate = await Isolate.spawn<_Bootstrap>(
        _workerMain,
        _Bootstrap(
          events: events.sendPort,
          config: config ?? AsrConfig(),
          allowDownload: allowDownload,
          factory: factory,
          rootToken: RootIsolateToken.instance,
        ),
        errorsAreFatal: true,
        onError: events.sendPort,
        onExit: events.sendPort,
        debugName: 'vsasr-asr',
      );
    } on Object {
      await subscription.cancel();
      events.close();
      rethrow;
    }

    try {
      final SendPort commands = await ready.future;
      return TranscriptionWorker._(isolate, commands, events, subscription, pending, exited, live);
    } on Object {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      events.close();
      rethrow;
    }
  }

  /// 转写一整条 16 kHz float32 单声道音频。
  ///
  /// 多个请求会在 isolate 内串行执行（同一个识别器不能并发用）。
  /// [onProgress] 的参数与 [AsrEngine.transcribe] 一致：已处理/总采样数。
  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) {
    if (_closed) {
      throw StateError('TranscriptionWorker 已关闭，请重新 start()');
    }
    final int id = _nextId++;
    final Completer<TranscriptionResult> completer = Completer<TranscriptionResult>();
    _pending[id] = _Pending(completer, onProgress);
    _commands.send(_TranscribeCommand(id, samples));
    return completer.future;
  }

  /// 关闭 worker：让 isolate 释放原生资源后自行退出，未完成的请求全部报错。
  ///
  /// [gracePeriod] 是等它自己退出的上限；超时就硬杀（正在解码的请求会卡住
  /// `await for`，收不到关闭命令，只能这样收场）。
  @override
  Future<void> dispose({Duration gracePeriod = const Duration(seconds: 5)}) async {
    if (_closed) return;
    _closed = true;
    // 录音还开着就先收尾：不然 isolate 里的 VAD 与流控制器不会被释放。
    // 但不能无限等 —— isolate 卡在某次解码里时 finish() 永远回不来，
    // 那样连「超时硬杀」这条兜底都走不到，退出流程直接挂死。
    final Future<void>? closingLive = _live.active?.finish();
    if (closingLive != null) {
      try {
        await closingLive.timeout(gracePeriod);
      } on TimeoutException {
        _failLive(_live, 'TranscriptionWorker 已关闭');
      }
    }
    _commands.send(const _ShutdownCommand());
    try {
      await _exited.future.timeout(gracePeriod);
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
    }
    _failAll(_pending, 'TranscriptionWorker 已关闭');
    await _subscription.cancel();
    _events.close();
  }

  /// 开一路实时识别。同一时刻只能有一路（同一个识别器不能并发用）。
  ///
  /// 音频块经命令端口送进 isolate，段经事件端口回来。麦克风采集本身留在
  /// 主 isolate（插件只在 root isolate 可用），这里只负责搬运。
  @override
  Future<LiveSession> startLive() async {
    if (_closed) {
      throw StateError('TranscriptionWorker 已关闭，请重新 start()');
    }
    if (_live.active != null) {
      throw StateError('已有一路实时识别在跑，先 finish() 再开新的');
    }
    final Completer<void> started = Completer<void>();
    final _WorkerLiveSession session = _WorkerLiveSession(_commands, _live);
    _live
      ..active = session
      ..starting = started;
    _commands.send(const _LiveStartCommand());
    try {
      await started.future;
    } on Object {
      _live
        ..active = null
        ..starting = null;
      rethrow;
    }
    _live.starting = null;
    return session;
  }

  /// 统一处理来自 isolate 的消息：启动阶段与运行阶段共用同一个端口。
  static void _dispatch(
    Object? message,
    Completer<SendPort> ready,
    Completer<void> exited,
    Map<int, _Pending> pending,
    _LiveHub live,
    ModelProgress? onModelProgress,
  ) {
    switch (message) {
      case _ReadyEvent(commands: final SendPort commands):
        if (!ready.isCompleted) ready.complete(commands);
      case _ModelProgressEvent(stage: final String stage, done: final int d, total: final int t):
        onModelProgress?.call(stage, d, t);
      case _ProgressEvent(id: final int id, done: final int d, total: final int t):
        pending[id]?.onProgress?.call(d, t);
      case _ResultEvent(id: final int id, result: final TranscriptionResult result):
        final _Pending? waiter = pending.remove(id);
        if (waiter != null && !waiter.completer.isCompleted) waiter.completer.complete(result);
      case _FailureEvent(id: final int id, message: final String detail):
        final _Pending? waiter = pending.remove(id);
        if (waiter != null && !waiter.completer.isCompleted) {
          waiter.completer.completeError(StateError(detail));
        }
      case _StartupFailureEvent(message: final String detail):
        if (!ready.isCompleted) ready.completeError(StateError(detail));
      case _LiveReadyEvent():
        final Completer<void>? starting = live.starting;
        if (starting != null && !starting.isCompleted) starting.complete();
      case _LiveSegmentEvent(segment: final Segment segment):
        live.active?.push(segment);
      case _LiveDoneEvent():
        live.active?.close();
        live.active = null;
      case _LiveFailureEvent(message: final String detail):
        _failLive(live, detail);
      // onError 端口回的是 [错误, 堆栈]；onExit 端口回 null。
      case final List<Object?> error:
        final String detail = error.isEmpty ? '未知错误' : '${error.first}';
        if (!ready.isCompleted) ready.completeError(StateError('识别 isolate 异常：$detail'));
        _failAll(pending, '识别 isolate 异常：$detail');
        _failLive(live, '识别 isolate 异常：$detail');
      case null:
        if (!exited.isCompleted) exited.complete();
        if (!ready.isCompleted) ready.completeError(StateError('识别 isolate 意外退出'));
        _failAll(pending, '识别 isolate 已退出');
        _failLive(live, '识别 isolate 已退出');
    }
  }

  static void _failLive(_LiveHub live, String message) {
    final Completer<void>? starting = live.starting;
    if (starting != null && !starting.isCompleted) {
      starting.completeError(StateError(message));
      return;
    }
    live.active?.fail(message);
    live.active = null;
  }

  static void _failAll(Map<int, _Pending> pending, String message) {
    for (final _Pending waiter in pending.values) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(StateError(message));
      }
    }
    pending.clear();
  }
}

/// 一个等待中的请求。
class _Pending {
  _Pending(this.completer, this.onProgress);

  final Completer<TranscriptionResult> completer;
  final TranscribeProgress? onProgress;
}

/// 主 isolate 侧的实时会话状态。`_dispatch` 是静态的，用它来共享可变状态。
class _LiveHub {
  _WorkerLiveSession? active;

  /// 正在等 isolate 确认「已开始」的 completer。
  Completer<void>? starting;
}

/// 主 isolate 侧的实时会话：命令走出去，段走回来。
class _WorkerLiveSession implements LiveSession {
  _WorkerLiveSession(this._commands, this._hub);

  final SendPort _commands;
  final _LiveHub _hub;
  final StreamController<Segment> _out = StreamController<Segment>.broadcast();
  final Completer<void> _done = Completer<void>();
  bool _finished = false;

  @override
  Stream<Segment> get segments => _out.stream;

  @override
  void accept(Float32List chunk) {
    if (_finished) return;
    _commands.send(_LiveChunkCommand(chunk));
  }

  @override
  Future<void> finish() async {
    if (_finished) return;
    _finished = true;
    _commands.send(const _LiveFinishCommand());
    await _done.future;
  }

  /// 收到一段识别结果。
  void push(Segment segment) {
    if (!_out.isClosed) _out.add(segment);
  }

  /// isolate 报告本路已收尾。
  void close() {
    if (!_out.isClosed) _out.close();
    if (!_done.isCompleted) _done.complete();
    _hub.active = null;
  }

  /// isolate 出错或死掉：把错误送给监听者，别让 finish() 永远挂着。
  void fail(String message) {
    if (!_out.isClosed) {
      _out.addError(StateError(message));
      _out.close();
    }
    if (!_done.isCompleted) _done.complete();
    _hub.active = null;
  }
}

/// `Isolate.spawn` 的入参。
class _Bootstrap {
  const _Bootstrap({
    required this.events,
    required this.config,
    required this.allowDownload,
    required this.factory,
    required this.rootToken,
  });

  final SendPort events;
  final AsrConfig config;
  final bool allowDownload;
  final TranscriberFactory factory;

  /// 让后台 isolate 能用平台通道（path_provider 解析模型目录要用）。
  /// 纯 Dart 环境（`flutter test` 之外）拿不到，允许为 null。
  final RootIsolateToken? rootToken;
}

class _TranscribeCommand {
  const _TranscribeCommand(this.id, this.samples);

  final int id;
  final Float32List samples;
}

class _ShutdownCommand {
  const _ShutdownCommand();
}

class _LiveStartCommand {
  const _LiveStartCommand();
}

class _LiveChunkCommand {
  const _LiveChunkCommand(this.samples);

  final Float32List samples;
}

class _LiveFinishCommand {
  const _LiveFinishCommand();
}

class _LiveReadyEvent {
  const _LiveReadyEvent();
}

class _LiveSegmentEvent {
  const _LiveSegmentEvent(this.segment);

  final Segment segment;
}

class _LiveDoneEvent {
  const _LiveDoneEvent();
}

class _LiveFailureEvent {
  const _LiveFailureEvent(this.message);

  final String message;
}

class _ReadyEvent {
  const _ReadyEvent(this.commands);

  final SendPort commands;
}

class _StartupFailureEvent {
  const _StartupFailureEvent(this.message);

  final String message;
}

class _ModelProgressEvent {
  const _ModelProgressEvent(this.stage, this.done, this.total);

  final String stage;
  final int done;
  final int total;
}

class _ProgressEvent {
  const _ProgressEvent(this.id, this.done, this.total);

  final int id;
  final int done;
  final int total;
}

class _ResultEvent {
  const _ResultEvent(this.id, this.result);

  final int id;
  final TranscriptionResult result;
}

class _FailureEvent {
  const _FailureEvent(this.id, this.message);

  final int id;
  final String message;
}

/// isolate 入口。必须是顶层函数。
Future<void> _workerMain(_Bootstrap bootstrap) async {
  final SendPort events = bootstrap.events;
  final ReceivePort commands = ReceivePort();

  // 平台通道默认只在 root isolate 上可用。模型目录要靠 path_provider 解析，
  // 不先接上这一步，`getApplicationSupportDirectory()` 会抛
  // "BackgroundIsolateBinaryMessenger.instance value is invalid"。
  final RootIsolateToken? rootToken = bootstrap.rootToken;
  if (rootToken != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
  }

  final Transcriber transcriber;
  try {
    transcriber = await bootstrap.factory(
      WorkerSetup._(bootstrap.config, bootstrap.allowDownload, events),
    );
  } on Object catch (error) {
    // 模型缺失、下载失败、原生库加载失败都走这里；主 isolate 的 start() 会抛出。
    events.send(_StartupFailureEvent('$error'));
    commands.close();
    Isolate.exit();
  }
  events.send(_ReadyEvent(commands.sendPort));

  // `await for` 天然串行：同一个识别器不能并发使用。
  LiveSession? live;
  StreamSubscription<Segment>? liveEvents;
  await for (final Object? message in commands) {
    if (message is _ShutdownCommand) break;

    if (message is _LiveStartCommand) {
      try {
        final LiveSession session = await transcriber.startLive();
        // 先订阅再回 ready：`accept` 之前必须已经有监听者，
        // 否则广播流会把最早的几段直接丢掉。
        liveEvents = session.segments.listen((Segment segment) {
          events.send(_LiveSegmentEvent(segment));
        });
        live = session;
        events.send(const _LiveReadyEvent());
      } on Object catch (error) {
        events.send(_LiveFailureEvent('$error'));
      }
      continue;
    }
    if (message is _LiveChunkCommand) {
      try {
        live?.accept(message.samples);
      } on Object catch (error) {
        events.send(_LiveFailureEvent('$error'));
      }
      continue;
    }
    if (message is _LiveFinishCommand) {
      try {
        // finish() 会等流里的段全部送达再关闭，因此 done 事件不会插到段前面。
        await live?.finish();
      } on Object catch (error) {
        events.send(_LiveFailureEvent('$error'));
      }
      await liveEvents?.cancel();
      liveEvents = null;
      live = null;
      events.send(const _LiveDoneEvent());
      continue;
    }

    if (message is! _TranscribeCommand) continue;
    try {
      final TranscriptionResult result = await transcriber.transcribe(
        message.samples,
        onProgress: (int done, int total) {
          events.send(_ProgressEvent(message.id, done, total));
        },
      );
      events.send(_ResultEvent(message.id, result));
    } on Object catch (error) {
      events.send(_FailureEvent(message.id, '$error'));
    }
  }

  // 关闭前把还开着的实时会话收掉：VAD 与流控制器都挂在它上面。
  if (live != null) {
    await live.finish();
    await liveEvents?.cancel();
  }
  await transcriber.dispose();
  commands.close();
  // 必须显式退出：`BackgroundIsolateBinaryMessenger.ensureInitialized` 会留一个
  // 常驻端口，光关掉 commands 端口这个 isolate 也不会自己结束，dispose() 只能
  // 每次都等满 gracePeriod 再硬杀。注意得先 dispose ——
  // 原生内存属于进程，isolate 退出并不会替你 free。
  Isolate.exit();
}
