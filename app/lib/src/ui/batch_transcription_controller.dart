/// 多文件顺序转写队列。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/diagnostics/performance_report.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';

/// 批量条目的生命周期。
enum BatchItemStatus {
  queued,
  processing,
  paused,
  completed,
  translating,
  translated,
  failed,
  translationFailed,
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

  factory BatchItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('批量条目必须是 JSON 对象');
    }
    final Object? rawPath = value['path'];
    if (rawPath is! String || rawPath.trim().isEmpty) {
      throw const FormatException('批量条目 path 必须是非空字符串');
    }
    final Object? rawStatus = value['status'];
    final BatchItemStatus status;
    try {
      status = BatchItemStatus.values.firstWhere(
        (BatchItemStatus candidate) => candidate.name == rawStatus,
      );
    } on StateError {
      throw FormatException('不支持的批量条目状态：$rawStatus');
    }
    final Object? rawProgress = value['progress'];
    final double? progress;
    if (rawProgress == null) {
      progress = null;
    } else if (rawProgress is num &&
        rawProgress.isFinite &&
        rawProgress >= 0 &&
        rawProgress <= 1) {
      progress = rawProgress.toDouble();
    } else {
      throw const FormatException('批量条目 progress 必须是 0 到 1 之间的数字');
    }
    final Object? rawAttempts = value['attempts'] ?? 0;
    if (rawAttempts is! int || rawAttempts < 0) {
      throw const FormatException('批量条目 attempts 必须是非负整数');
    }
    final Object? rawError = value['error_text'];
    if (rawError != null && rawError is! String) {
      throw const FormatException('批量条目 error_text 必须是字符串或 null');
    }
    final Object? rawResult = value['result'];
    final TranscriptionResult? result = rawResult == null
        ? null
        : TranscriptionResult.fromJson(rawResult);
    if (result != null) {
      ensureValidSubtitleTimeline(result.segments, duration: result.duration);
    }
    return BatchItem(
      path: rawPath.trim(),
      status: status,
      progress: progress,
      result: result,
      errorText: rawError as String?,
      attempts: rawAttempts,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'status': status.name,
    'progress': progress,
    'result': result?.toJson(),
    'error_text': errorText,
    'attempts': attempts,
  };

  bool get finished =>
      status == BatchItemStatus.completed ||
      status == BatchItemStatus.translated ||
      status == BatchItemStatus.failed ||
      status == BatchItemStatus.translationFailed ||
      status == BatchItemStatus.cancelled;

  String get statusLabel => switch (status) {
    BatchItemStatus.queued => '等待中',
    BatchItemStatus.processing => '处理中',
    BatchItemStatus.paused => '已暂停',
    BatchItemStatus.completed => '已完成',
    BatchItemStatus.translating => '翻译中',
    BatchItemStatus.translated => '已完成翻译',
    BatchItemStatus.failed => '失败',
    BatchItemStatus.translationFailed => '翻译失败',
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

/// 一个文件成功翻译后触发的辅助持久化回调。
typedef BatchTranslationResultCallback = FutureOr<void> Function(
  BatchItem item,
);

/// 顺序处理多个文件，复用主控制器中已经加载的识别模型。
///
/// 先顺序识别文件，再用同一个 provider 顺序翻译已完成的结果。
class BatchTranscriptionController extends ChangeNotifier {
  BatchTranscriptionController({required this.transcriber}) {
    transcriber.addListener(_onTranscriberChanged);
  }

  final TranscribeController transcriber;
  final List<BatchItem> _items = <BatchItem>[];
  bool _running = false;
  bool _translating = false;
  bool _paused = false;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  int? _currentIndex;
  Future<void>? _runFuture;
  final Map<String, PerformanceReport> _performanceReports =
      <String, PerformanceReport>{};
  Duration? _modelPreparationElapsed;
  DateTime? _performanceGeneratedAt;
  bool _hasRun = false;

  List<BatchItem> get items => List<BatchItem>.unmodifiable(_items);

  bool get running => _running;

  bool get translating => _translating;

  bool get paused => _paused;

  int? get currentIndex => _currentIndex;

  /// 最近一次批量识别的聚合性能报告；尚未运行队列时为 null。
  BatchPerformanceReport? get performanceReport {
    if (!_hasRun) return null;
    final int failedCount = _items
        .where(
          (BatchItem item) =>
              item.status == BatchItemStatus.failed ||
              item.status == BatchItemStatus.translationFailed,
        )
        .length;
    final int cancelledCount = _items
        .where((BatchItem item) => item.status == BatchItemStatus.cancelled)
        .length;
    return BatchPerformanceReport(
      generatedAt: _performanceGeneratedAt ??= DateTime.now(),
      totalCount: _items.length,
      completedCount: completedCount,
      failedCount: failedCount,
      cancelledCount: cancelledCount,
      modelPreparationElapsed: _modelPreparationElapsed,
      reports: _performanceReports.values,
    );
  }

  BatchItem? get currentItem {
    final int? index = _currentIndex;
    if (index == null || index < 0 || index >= _items.length) return null;
    return _items[index];
  }

  bool get hasQueuedItems =>
      _items.any((BatchItem item) => item.status == BatchItemStatus.queued);

  bool get hasTranslatableItems => _items.any(
    (BatchItem item) =>
        item.status == BatchItemStatus.completed ||
        item.status == BatchItemStatus.translationFailed,
  );

  bool get hasExportableItems => _items.any(
    (BatchItem item) =>
        (item.status == BatchItemStatus.completed ||
            item.status == BatchItemStatus.translated) &&
        item.result != null,
  );

  int get completedCount => _items
      .where(
        (BatchItem item) =>
            item.status == BatchItemStatus.completed ||
            item.status == BatchItemStatus.translated,
      )
      .length;

  int get translatedCount => _items
      .where((BatchItem item) => item.status == BatchItemStatus.translated)
      .length;

  /// 追加文件并去除空路径和重复项。
  void enqueue(Iterable<String> paths) {
    if (_running) throw StateError('批量处理进行中，暂时不能添加文件');
    final int initialCount = _items.length;
    final Set<String> existing = _items
        .map((BatchItem item) => item.path)
        .toSet();
    for (final String rawPath in paths) {
      final String path = rawPath.trim();
      if (path.isEmpty || !existing.add(path)) continue;
      _items.add(BatchItem(path: path));
    }
    if (_items.length != initialCount) {
      _hasRun = false;
      _performanceReports.clear();
      _modelPreparationElapsed = null;
      _performanceGeneratedAt = null;
      _notify();
    }
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
    _hasRun = true;
    _paused = false;
    _pauseRequested = false;
    _cancelRequested = false;
    _notify();
    final Future<void> future = _runQueue();
    _runFuture = future;
    return future;
  }

  /// 顺序翻译已经完成识别的文件，并在整个队列中复用同一个 provider。
  ///
  /// provider 的创建和释放由调用方负责；这样 API provider 内部的 HTTP client
  /// 可以跨文件复用连接池，同时不会把 API Key 或 provider 生命周期塞进队列。
  Future<void> translateAll(
    TranslationProvider provider, {
    required String targetLanguage,
    int batchSize = 20,
    int maxRetries = 2,
    Duration retryDelay = const Duration(milliseconds: 250),
    BatchTranslationResultCallback? onItemTranslated,
  }) {
    if (_running || _paused) {
      return Future<void>.error(StateError('批量处理进行中，请稍后再翻译'));
    }
    if (targetLanguage.trim().isEmpty) {
      return Future<void>.error(
        ArgumentError.value(targetLanguage, 'targetLanguage', '目标语言不能为空'),
      );
    }
    if (batchSize < 1) {
      return Future<void>.error(
        ArgumentError.value(batchSize, 'batchSize', '必须 >= 1'),
      );
    }
    if (maxRetries < 0) {
      return Future<void>.error(
        ArgumentError.value(maxRetries, 'maxRetries', '不能为负'),
      );
    }
    if (retryDelay.isNegative) {
      return Future<void>.error(
        ArgumentError.value(retryDelay, 'retryDelay', '不能为负'),
      );
    }
    if (!hasTranslatableItems) return Future<void>.value();

    _running = true;
    _translating = true;
    _cancelRequested = false;
    _currentIndex = null;
    _notify();
    final Future<void> future = _runTranslationQueue(
      provider,
      targetLanguage: targetLanguage,
      batchSize: batchSize,
      maxRetries: maxRetries,
      retryDelay: retryDelay,
      onItemTranslated: onItemTranslated,
    );
    _runFuture = future;
    return future;
  }

  /// 请求在当前文件完成后暂停，避免中断并留下不可用的局部结果。
  void pause() {
    if (!_running || _translating) return;
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
    if (_translating) {
      // 翻译请求本身由 provider 控制，取消只阻止当前请求完成后写回，
      // 并保留尚未翻译的识别结果，用户可以再次点击批量翻译继续。
    } else {
      _markWaiting(BatchItemStatus.cancelled);
    }
    if (_paused && !_running) _paused = false;
    _notify();
    final Future<void> close = !_translating && transcriber.busy
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
    _performanceReports.remove(item.path);
    _notify();
    return start();
  }

  /// 将翻译失败的条目标记为待翻译；实际请求由页面在确认 provider 后发起。
  void retryTranslation(int index) {
    if (index < 0 || index >= _items.length) {
      throw RangeError.index(index, _items);
    }
    final BatchItem item = _items[index];
    if (item.status != BatchItemStatus.translationFailed) {
      throw StateError('只有翻译失败的批量条目可以重试');
    }
    if (_running) throw StateError('批量处理进行中，暂时不能重试');
    _items[index] = item.copyWith(
      status: BatchItemStatus.completed,
      clearProgress: true,
      clearError: true,
    );
    _notify();
  }

  /// 清空未运行的批量队列；用于用户放弃恢复或重新开始一批文件。
  void clear() {
    if (_running || _paused) {
      throw StateError('批量处理进行中，暂时不能清空队列');
    }
    if (_items.isEmpty) return;
    _items.clear();
    _currentIndex = null;
    _hasRun = false;
    _performanceReports.clear();
    _modelPreparationElapsed = null;
    _performanceGeneratedAt = null;
    _notify();
  }

  /// 恢复持久化快照；旧的 processing/translating 状态会降级为可继续状态。
  void restore(Iterable<BatchItem> restoredItems) {
    if (_running || _paused) {
      throw StateError('批量处理进行中，暂时不能恢复队列');
    }
    final Set<String> paths = <String>{};
    final List<BatchItem> normalized = <BatchItem>[];
    for (final BatchItem item in restoredItems) {
      final String path = item.path.trim();
      if (path.isEmpty || !paths.add(path)) continue;
      normalized.add(_normalizeRecoveredItem(item, path));
    }
    _items
      ..clear()
      ..addAll(normalized);
    _hasRun = false;
    _performanceReports.clear();
    _modelPreparationElapsed = null;
    _performanceGeneratedAt = null;
    _notify();
  }

  /// 应用经过指纹校验的本地缓存译文，不触发网络请求。
  void applyCachedTranslation(int index, TranscriptionResult translated) {
    if (index < 0 || index >= _items.length) {
      throw RangeError.index(index, _items);
    }
    final BatchItem item = _items[index];
    final TranscriptionResult? source = item.result;
    if ((item.status != BatchItemStatus.completed &&
            item.status != BatchItemStatus.translationFailed) ||
        source == null) {
      throw StateError('当前条目没有可复用的识别结果');
    }
    ensureValidSubtitleTimeline(
      translated.segments,
      duration: translated.duration,
    );
    if (!_sameSource(source, translated)) {
      throw StateError('本地翻译缓存与当前识别结果不匹配');
    }
    _items[index] = item.copyWith(
      status: BatchItemStatus.translated,
      progress: 1,
      result: translated,
      clearError: true,
    );
    _notify();
  }

  Future<void> _runQueue() async {
    try {
      // 先准备模型，使取消发生在模型准备阶段时也能在这里安全收尾。
      final Stopwatch preparationWatch = Stopwatch()..start();
      await transcriber.prepare();
      _modelPreparationElapsed ??= preparationWatch.elapsed;
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
          _performanceReports.remove(item.path);
          _items[next] = _items[next].copyWith(
            status: BatchItemStatus.failed,
            clearProgress: true,
            errorText: error ?? '未得到有效识别结果',
            clearResult: true,
          );
        } else {
          final PerformanceReport? report = transcriber.performanceReport;
          if (report != null) _performanceReports[item.path] = report;
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
      _translating = false;
      _runFuture = null;
      _cancelRequested = false;
      _notify();
    }
  }

  Future<void> _runTranslationQueue(
    TranslationProvider provider, {
    required String targetLanguage,
    required int batchSize,
    required int maxRetries,
    required Duration retryDelay,
    required BatchTranslationResultCallback? onItemTranslated,
  }) async {
    final Set<int> attempted = <int>{};
    try {
      while (!_cancelRequested) {
        final int? next = _nextTranslatableIndex(attempted);
        if (next == null) return;
        attempted.add(next);
        _currentIndex = next;
        final BatchItem item = _items[next];
        final TranscriptionResult? source = item.result;
        if (source == null) {
          _items[next] = item.copyWith(
            status: BatchItemStatus.translationFailed,
            clearProgress: true,
            errorText: '缺少可翻译的识别结果',
          );
          _notify();
          continue;
        }
        _items[next] = item.copyWith(
          status: BatchItemStatus.translating,
          progress: 0,
          clearError: true,
        );
        _notify();
        try {
          final TranscriptionResult translated = await translateResult(
            source,
            provider,
            to: targetLanguage,
            batchSize: batchSize,
            maxRetries: maxRetries,
            retryDelay: retryDelay,
            onProgress: (int done, int total) {
              if (_cancelRequested ||
                  !_translating ||
                  _currentIndex != next ||
                  _items[next].status != BatchItemStatus.translating) {
                return;
              }
              _items[next] = _items[next].copyWith(
                progress: total > 0 ? done / total : 1,
              );
              _notify();
            },
          );
          if (_cancelRequested) {
            _items[next] = _items[next].copyWith(
              status: BatchItemStatus.completed,
              clearProgress: true,
              clearError: true,
            );
            _notify();
            return;
          }
          _items[next] = _items[next].copyWith(
            status: BatchItemStatus.translated,
            progress: 1,
            result: translated,
            clearError: true,
          );
          try {
            await onItemTranslated?.call(_items[next]);
          } on Object {
            // 缓存是辅助能力，写入失败不能让已经成功的翻译变成失败。
          }
        } on Object catch (error) {
          if (_cancelRequested) {
            _items[next] = _items[next].copyWith(
              status: BatchItemStatus.completed,
              clearProgress: true,
              clearError: true,
            );
            _notify();
            return;
          }
          _items[next] = _items[next].copyWith(
            status: BatchItemStatus.translationFailed,
            clearProgress: true,
            errorText: _humanize(error),
          );
        }
        _notify();
      }
    } finally {
      _currentIndex = null;
      _running = false;
      _translating = false;
      _runFuture = null;
      _cancelRequested = false;
      _notify();
    }
  }

  int? _nextQueuedIndex() {
    for (int i = 0; i < _items.length; i++) {
      if (_items[i].status == BatchItemStatus.queued) return i;
    }
    return null;
  }

  int? _nextTranslatableIndex(Set<int> attempted) {
    for (int i = 0; i < _items.length; i++) {
      if (attempted.contains(i)) continue;
      final BatchItemStatus status = _items[i].status;
      if (status == BatchItemStatus.completed ||
          status == BatchItemStatus.translationFailed) {
        return i;
      }
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

  String _humanize(Object error) {
    final String raw = error is StateError ? error.message : '$error';
    return raw.replaceFirst(RegExp(r'^(Bad state: |Exception: )+'), '');
  }

  bool _sameSource(TranscriptionResult source, TranscriptionResult other) {
    if (source.language != other.language ||
        source.duration != other.duration ||
        source.segments.length != other.segments.length) {
      return false;
    }
    for (int i = 0; i < source.segments.length; i++) {
      final Segment left = source.segments[i];
      final Segment right = other.segments[i];
      if (left.text != right.text ||
          left.start != right.start ||
          left.end != right.end ||
          left.index != right.index ||
          left.language != right.language) {
        return false;
      }
    }
    return true;
  }

  BatchItem _normalizeRecoveredItem(BatchItem item, String path) {
    final BatchItem normalized = BatchItem(
      path: path,
      status: item.status,
      progress: item.progress,
      result: item.result,
      errorText: item.errorText,
      attempts: item.attempts,
    );
    switch (normalized.status) {
      case BatchItemStatus.processing:
        return normalized.copyWith(
          status: BatchItemStatus.queued,
          clearProgress: true,
          clearError: true,
        );
      case BatchItemStatus.translating:
        return normalized.copyWith(
          status: normalized.result == null
              ? BatchItemStatus.queued
              : BatchItemStatus.completed,
          clearProgress: true,
          clearError: true,
        );
      default:
        return normalized;
    }
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
