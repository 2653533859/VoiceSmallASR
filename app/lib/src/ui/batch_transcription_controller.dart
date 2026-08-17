/// 多文件顺序转写队列。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

/// 批量条目的生命周期。
enum BatchItemStatus {
  queued,
  processing,
  paused,
  completed,
  failed,
  cancelled,
}

/// 一个批量文件及其当前快照。
class BatchItem {
  const BatchItem({
    required this.path,
    this.status = BatchItemStatus.queued,
    this.progress,
    this.result,
    this.errorText,
    this.attempts = 0,
  });

  final String path;
  final BatchItemStatus status;
  final double? progress;
  final TranscriptionResult? result;
  final String? errorText;
  final int attempts;

  bool get finished =>
      status == BatchItemStatus.completed ||
      status == BatchItemStatus.failed ||
      status == BatchItemStatus.cancelled;

  String get statusLabel => switch (status) {
    BatchItemStatus.queued => '等待中',
    BatchItemStatus.processing => '处理中',
    BatchItemStatus.paused => '已暂停',
    BatchItemStatus.completed => '已完成',
    BatchItemStatus.failed => '失败',
    BatchItemStatus.cancelled => '已取消',
  };

  BatchItem copyWith({
    BatchItemStatus? status,
    double? progress,
    TranscriptionResult? result,
    String? errorText,
    int? attempts,
    bool clearProgress = false,
    bool clearResult = false,
    bool clearError = false,
  }) {
    return BatchItem(
      path: path,
      status: status ?? this.status,
      progress: clearProgress ? null : progress ?? this.progress,
      result: clearResult ? null : result ?? this.result,
      errorText: clearError ? null : errorText ?? this.errorText,
      attempts: attempts ?? this.attempts,
    );
  }
}

/// 选择多个音频或视频文件，取消时返回空列表。
typedef PickBatchFiles = Future<List<String>> Function();

/// 顺序处理多个文件，复用主控制器中已经加载的识别模型。
///
/// 当前阶段只负责批量识别。翻译、导出和缓存会在队列状态稳定后接入，避免
/// 在单文件结果尚未可靠落地时产生半成品文件。
class BatchTranscriptionController extends ChangeNotifier {
  BatchTranscriptionController({required this.transcriber}) {
    transcriber.addListener(_onTranscriberChanged);
  }

  final TranscribeController transcriber;
  final List<BatchItem> _items = <BatchItem>[];
  bool _running = false;
  bool _paused = false;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  int? _currentIndex;
  Future<void>? _runFuture;

  List<BatchItem> get items => List<BatchItem>.unmodifiable(_items);

  bool get running => _running;

  bool get paused => _paused;

  int? get currentIndex => _currentIndex;

  BatchItem? get currentItem {
    final int? index = _currentIndex;
    if (index == null || index < 0 || index >= _items.length) return null;
    return _items[index];
  }

  bool get hasQueuedItems =>
      _items.any((BatchItem item) => item.status == BatchItemStatus.queued);

  int get completedCount => _items
      .where((BatchItem item) => item.status == BatchItemStatus.completed)
      .length;

  /// 追加文件并去除空路径和重复项。
  void enqueue(Iterable<String> paths) {
    if (_running) throw StateError('批量处理进行中，暂时不能添加文件');
    final Set<String> existing = _items
        .map((BatchItem item) => item.path)
        .toSet();
    for (final String rawPath in paths) {
      final String path = rawPath.trim();
      if (path.isEmpty || !existing.add(path)) continue;
      _items.add(BatchItem(path: path));
    }
    if (paths.isNotEmpty) _notify();
  }

  /// 开始或继续队列；同一时间只允许一个运行循环。
  Future<void> start() {
    if (_running) return _runFuture ?? Future<void>.value();
    if (transcriber.busy) {
      return Future<void>.error(StateError('当前正在处理另一个文件，请稍后再启动批量处理'));
    }
    if (!hasQueuedItems && !_paused) return Future<void>.value();
    for (int i = 0; i < _items.length; i++) {
      if (_items[i].status == BatchItemStatus.paused) {
        _items[i] = _items[i].copyWith(status: BatchItemStatus.queued);
      }
    }
    _running = true;
    _paused = false;
    _pauseRequested = false;
    _cancelRequested = false;
    _notify();
    final Future<void> future = _runQueue();
    _runFuture = future;
    return future;
  }

  /// 请求在当前文件完成后暂停，避免中断并留下不可用的局部结果。
  void pause() {
    if (!_running) return;
    _pauseRequested = true;
    _notify();
  }

  /// 继续处理暂停的条目。
  Future<void> resume() => start();

  /// 取消当前和后续条目；当前识别 worker 会被关闭，结果不会写入条目。
  Future<void> cancel() async {
    if (!_running && !_paused) return;
    _cancelRequested = true;
    _pauseRequested = false;
    _markWaiting(BatchItemStatus.cancelled);
    _notify();
    final Future<void> close = transcriber.busy
        ? transcriber.cancelCurrentTask()
        : Future<void>.value();
    final Future<void>? run = _runFuture;
    await Future.wait<void>(<Future<void>>[close, ?run]);
  }

  /// 只允许失败条目重试；重试不会自动重跑已经完成的文件。
  Future<void> retry(int index) {
    if (index < 0 || index >= _items.length) {
      throw RangeError.index(index, _items);
    }
    final BatchItem item = _items[index];
    if (item.status != BatchItemStatus.failed) {
      throw StateError('只有失败的批量条目可以重试');
    }
    if (_running) throw StateError('批量处理进行中，暂时不能重试');
    _items[index] = item.copyWith(
      status: BatchItemStatus.queued,
      progress: 0,
      clearResult: true,
      clearError: true,
    );
    _notify();
    return start();
  }

  Future<void> _runQueue() async {
    try {
      // 先准备模型，使取消发生在模型准备阶段时也能在这里安全收尾。
      await transcriber.prepare();
      if (_cancelRequested) {
        await transcriber.cancelCurrentTask();
        _markWaiting(BatchItemStatus.cancelled);
        return;
      }
      while (true) {
        if (_cancelRequested) {
          _markWaiting(BatchItemStatus.cancelled);
          return;
        }
        if (_pauseRequested) {
          _markWaiting(BatchItemStatus.paused);
          _paused = _items.any(
            (BatchItem item) => item.status == BatchItemStatus.paused,
          );
          return;
        }
        final int? next = _nextQueuedIndex();
        if (next == null) return;
        _currentIndex = next;
        final BatchItem item = _items[next];
        _items[next] = item.copyWith(
          status: BatchItemStatus.processing,
          progress: 0,
          attempts: item.attempts + 1,
          clearResult: true,
          clearError: true,
        );
        _notify();

        await transcriber.transcribeFile(item.path);
        if (_cancelRequested) {
          _items[next] = _items[next].copyWith(
            status: BatchItemStatus.cancelled,
            clearProgress: true,
            clearResult: true,
            clearError: true,
          );
          _markWaiting(BatchItemStatus.cancelled);
          _notify();
          return;
        }
        final TranscriptionResult? result = transcriber.result;
        final String? error = transcriber.errorText;
        if (result == null ||
            error != null ||
            transcriber.filePath != item.path) {
          _items[next] = _items[next].copyWith(
            status: BatchItemStatus.failed,
            clearProgress: true,
            errorText: error ?? '未得到有效识别结果',
            clearResult: true,
          );
        } else {
          _items[next] = _items[next].copyWith(
            status: BatchItemStatus.completed,
            progress: 1,
            result: result,
            clearError: true,
          );
        }
        _notify();
      }
    } finally {
      _currentIndex = null;
      _running = false;
      _runFuture = null;
      _notify();
    }
  }

  int? _nextQueuedIndex() {
    for (int i = 0; i < _items.length; i++) {
      if (_items[i].status == BatchItemStatus.queued) return i;
    }
    return null;
  }

  void _markWaiting(BatchItemStatus status) {
    for (int i = 0; i < _items.length; i++) {
      final BatchItem item = _items[i];
      if (item.status == BatchItemStatus.queued ||
          item.status == BatchItemStatus.paused) {
        _items[i] = item.copyWith(
          status: status,
          clearProgress: true,
          clearResult: true,
          clearError: status != BatchItemStatus.failed,
        );
      }
    }
  }

  void _onTranscriberChanged() {
    final int? index = _currentIndex;
    if (!_running ||
        index == null ||
        _items[index].status != BatchItemStatus.processing) {
      return;
    }
    final double? progress = transcriber.progress;
    if (progress == null || progress == _items[index].progress) return;
    _items[index] = _items[index].copyWith(progress: progress);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    transcriber.removeListener(_onTranscriberChanged);
    if (_running || _paused) {
      _cancelRequested = true;
      unawaited(transcriber.cancelCurrentTask());
    }
    super.dispose();
  }
}
