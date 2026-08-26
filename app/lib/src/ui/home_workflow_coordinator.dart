/// 首页项目恢复、批量队列与性能历史的业务协调器。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:vsasr_app/src/diagnostics/performance_log_store.dart';
import 'package:vsasr_app/src/diagnostics/performance_report.dart';
import 'package:vsasr_app/src/project/project_file.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/ui/batch_queue_store.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';
import 'package:vsasr_app/src/ui/live_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

/// 首页辅助持久化失败时交给界面显示的错误回调。
typedef HomeWorkflowErrorCallback = void Function(String message);

/// 项目恢复弹窗回调：true 表示恢复成功，false 表示用户明确放弃，null 表示取消或恢复失败。
typedef HomeProjectRecoveryCallback = Future<bool?> Function(
  VsasrProject project,
);

/// 批量队列恢复弹窗回调：true 表示恢复，false 表示放弃，null 表示取消。
typedef HomeBatchRecoveryCallback = Future<bool?> Function(
  BatchQueueSnapshot snapshot,
  int pendingCount,
);

/// 集中管理首页跨页面生命周期的业务状态，不持有 [BuildContext]。
class HomeWorkflowCoordinator extends ChangeNotifier
    with WidgetsBindingObserver {
  HomeWorkflowCoordinator({
    required this.controller,
    required this.live,
    required this._settings,
    required this._autosave,
    required this._batchQueue,
    required this._performanceLog,
    required this.onError,
  }) : batch = BatchTranscriptionController(transcriber: controller);

  final TranscribeController controller;
  final LiveController? live;
  final HomeWorkflowErrorCallback onError;
  final AppSettingsRepository? _settings;
  final ProjectAutosaveStore _autosave;
  final BatchQueueStore _batchQueue;
  final PerformanceLogStore _performanceLog;

  final BatchTranscriptionController batch;
  final List<PerformanceLogEntry> _performanceHistory = <PerformanceLogEntry>[];
  final Set<String> _performanceHistoryKeys = <String>{};

  List<String> _recentProjects = <String>[];
  int _recentProjectsGeneration = 0;
  Timer? _autosaveTimer;
  Future<void>? _autosaveFuture;
  int _autosaveRequestedRevision = 0;
  int _autosavedRevision = 0;
  bool _autosaveFailureNotified = false;
  Timer? _batchQueueTimer;
  Future<void>? _batchQueueFuture;
  int _batchQueueRequestedRevision = 0;
  int _batchQueueSavedRevision = 0;
  bool _batchQueueFailureNotified = false;
  bool _batchQueueRecoveryPromptShown = false;
  Future<void>? _performanceHistoryLoad;
  Future<void> _performanceWriteChain = Future<void>.value();
  bool _batchWasRunning = false;
  bool _liveWasBusy = false;
  bool _recoveryPromptShown = false;
  bool _detached = false;
  bool _sessionEnded = false;
  bool _initialized = false;
  bool _disposed = false;

  List<String> get recentProjects => List<String>.unmodifiable(_recentProjects);

  List<PerformanceLogEntry> get performanceHistory =>
      List<PerformanceLogEntry>.unmodifiable(_performanceHistory);

  bool get hasPerformanceHistory => _performanceHistory.isNotEmpty;

  bool get batchBusy => batch.running || batch.paused;

  /// 注册监听并启动性能历史加载；恢复和最近项目在首帧之后由页面调用。
  void init() {
    if (_initialized || _disposed) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_onControllerChanged);
    batch.addListener(_onBatchChanged);
    if (live != null) {
      _liveWasBusy = live!.busy;
      live!.addListener(_onLiveChanged);
    }
    _performanceHistoryLoad = _loadPerformanceHistory();
  }

  Future<void> loadRecentProjects() async {
    final int generation = _recentProjectsGeneration;
    try {
      final AppSettingsRepository settings =
          _settings ?? AppSettingsRepository();
      final List<String> projects = await settings.loadRecentProjects();
      if (_disposed || generation != _recentProjectsGeneration) return;
      _recentProjects = projects;
      notifyListeners();
    } on Object {
      // 最近项目只是辅助入口，偏好存储不可用时不影响主流程。
    }
  }

  Future<void> rememberRecentProject(String path) async {
    final String? normalizedPath = normalizeRecentProjectPath(path);
    if (normalizedPath == null) return;
    final int generation = ++_recentProjectsGeneration;
    try {
      final AppSettingsRepository settings =
          _settings ?? AppSettingsRepository();
      final List<String> projects = await settings.rememberRecentProject(
        normalizedPath,
      );
      if (_disposed || generation != _recentProjectsGeneration) return;
      _recentProjects = projects;
      notifyListeners();
    } on Object {
      // 保存/打开已成功时，最近项目写入失败不应覆盖主结果。
    }
  }

  /// 项目文件的默认读取器使用 dart:io；外部 URI 会先复制到应用支持目录。
  String? normalizeRecentProjectPath(String path) {
    final String value = path.trim();
    if (value.isEmpty) return null;
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return value;
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || uri.scheme.isEmpty) return value;
    if (uri.scheme == 'file') {
      try {
        return uri.toFilePath();
      } on Object {
        return null;
      }
    }
    return null;
  }

  Future<String?> projectPathForRecent({
    required VsasrProject project,
    required String? externalPath,
    required String identity,
    bool refreshCache = false,
  }) async {
    if (Platform.isAndroid &&
        externalPath != null &&
        _recentProjects.contains(externalPath) &&
        !refreshCache) {
      return externalPath;
    }
    if (!Platform.isAndroid && externalPath != null) {
      final String? normalized = normalizeRecentProjectPath(externalPath);
      if (normalized != null) return normalized;
    }
    try {
      return await const ProjectFileStore().cacheForRecentProject(
        project,
        identity: identity,
      );
    } on Object {
      // 最近项目只是辅助入口，缓存失败不应阻断项目打开或保存。
      return null;
    }
  }

  Future<void> loadRecovery({
    required HomeProjectRecoveryCallback onProjectRecovery,
    required HomeBatchRecoveryCallback onBatchRecovery,
  }) async {
    bool unclean = false;
    try {
      unclean = await _autosave.wasPreviousSessionUnclean();
      await _autosave.beginSession();
      if (_disposed) {
        await _autosave.endSession();
        return;
      }
      _sessionEnded = false;
      if (!unclean) return;
      final VsasrProject? project = await _autosave.load();
      if (!_disposed && project != null && !_recoveryPromptShown) {
        _recoveryPromptShown = true;
        final bool? decision = await onProjectRecovery(project);
        if (decision == false) {
          try {
            await _autosave.clear();
          } on Object {
            // 用户已明确放弃；清理失败不影响主界面继续使用。
          }
        }
      }
    } on Object {
      // 恢复快照是辅助数据，损坏或不可读时不能阻塞主界面启动。
    }
    if (unclean && !_disposed) {
      await _loadBatchQueueRecovery(onBatchRecovery);
    }
  }

  Future<void> _loadBatchQueueRecovery(
    HomeBatchRecoveryCallback onBatchRecovery,
  ) async {
    if (_batchQueueRecoveryPromptShown || _disposed) return;
    final BatchQueueSnapshot? snapshot;
    try {
      snapshot = await _batchQueue.load();
    } on Object {
      return;
    }
    if (_disposed || snapshot == null || !snapshot.hasRecoverableWork) return;
    _batchQueueRecoveryPromptShown = true;
    final int pendingCount = snapshot.items
        .where(
          (BatchItem item) =>
              item.status != BatchItemStatus.completed &&
              item.status != BatchItemStatus.translated &&
              item.status != BatchItemStatus.cancelled,
        )
        .length;
    final bool? decision = await onBatchRecovery(snapshot, pendingCount);
    if (_disposed) return;
    if (decision == true) {
      try {
        batch.restore(snapshot.items);
        onError('已恢复 ${snapshot.items.length} 个批量任务');
      } on Object catch (error) {
        onError('恢复批量任务失败：$error');
      }
      return;
    }
    if (decision == false) {
      batch.clear();
      try {
        await _batchQueue.clear();
      } on Object {
        // 用户已明确放弃；清理失败不阻塞主界面继续使用。
      }
    }
  }

  Future<void> clearPerformanceHistory() async {
    await _performanceWriteChain;
    await _performanceLog.clear();
    if (_disposed) return;
    _performanceHistory.clear();
    _performanceHistoryKeys.clear();
    notifyListeners();
  }

  void _onControllerChanged() {
    if (_detached || _disposed) return;
    final PerformanceReport? report = controller.performanceReport;
    if (report != null) _recordPerformance('file', report.toJson());
    if (controller.result == null ||
        controller.projectRevision <= _autosavedRevision) {
      return;
    }
    _autosaveRequestedRevision = controller.projectRevision;
    _autosaveFailureNotified = false;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(milliseconds: 400), () {
      _autosaveTimer = null;
      unawaited(_flushAutosave());
    });
  }

  Future<void> _flushAutosave() async {
    if (_detached || _disposed || _autosaveFuture != null) return;
    final int revision = _autosaveRequestedRevision;
    if (revision <= _autosavedRevision || controller.result == null) return;
    final VsasrProject project;
    try {
      project = controller.projectSnapshot;
    } on Object {
      return;
    }
    final Future<void> operation = _autosave.save(project);
    _autosaveFuture = operation;
    try {
      await operation;
      _autosavedRevision = revision;
    } on Object catch (error) {
      if (!_autosaveFailureNotified) {
        _autosaveFailureNotified = true;
        onError('自动保存失败，仍可手动保存项目：$error');
      }
    } finally {
      if (identical(_autosaveFuture, operation)) _autosaveFuture = null;
      if (!_detached &&
          !_disposed &&
          controller.projectRevision > _autosavedRevision &&
          controller.result != null) {
        _onControllerChanged();
      }
    }
  }

  void _onBatchChanged() {
    if (_detached || _disposed) return;
    final bool wasRunning = _batchWasRunning;
    _batchWasRunning = batch.running;
    if (wasRunning && !batch.running) {
      final BatchPerformanceReport? report = batch.performanceReport;
      if (report != null) _recordPerformance('batch', report.toJson());
    }
    _batchQueueRequestedRevision++;
    _batchQueueFailureNotified = false;
    _batchQueueTimer?.cancel();
    _batchQueueTimer = Timer(const Duration(milliseconds: 400), () {
      _batchQueueTimer = null;
      unawaited(_flushBatchQueue());
    });
    notifyListeners();
  }

  void _onLiveChanged() {
    if (_detached || _disposed) return;
    final LiveController? currentLive = live;
    if (currentLive == null) return;
    final bool wasBusy = _liveWasBusy;
    _liveWasBusy = currentLive.busy;
    if (wasBusy && !currentLive.busy) {
      final LivePerformanceReport? report = currentLive.performanceReport;
      if (report != null) _recordPerformance('live', report.toJson());
    }
  }

  Future<void> _loadPerformanceHistory() async {
    try {
      final List<PerformanceLogEntry> entries = await _performanceLog.load();
      if (_disposed) return;
      _performanceHistory
        ..clear()
        ..addAll(entries.reversed);
      _performanceHistoryKeys
        ..clear()
        ..addAll(entries.map((PerformanceLogEntry entry) => entry.key));
      notifyListeners();
    } on Object {
      // 性能历史是辅助信息，损坏或不可写时不影响主流程。
    }
  }

  void _recordPerformance(String kind, Map<String, Object?> report) {
    final Object? rawGeneratedAt = report['generated_at'];
    if (rawGeneratedAt is! String) return;
    final DateTime? generatedAt = DateTime.tryParse(rawGeneratedAt);
    if (generatedAt == null) return;
    unawaited(
      _persistPerformance(
        PerformanceLogEntry(
          kind: kind,
          generatedAt: generatedAt,
          report: report,
        ),
      ),
    );
  }

  Future<void> _persistPerformance(PerformanceLogEntry entry) async {
    final Future<void>? loading = _performanceHistoryLoad;
    if (loading != null) await loading;
    if (_detached || _disposed || !_performanceHistoryKeys.add(entry.key)) {
      return;
    }
    final Future<void> previous = _performanceWriteChain;
    final Future<void> operation = previous.then<void>((_) async {
      if (_detached || _disposed) return;
      await _performanceLog.append(entry);
      if (_disposed) return;
      _performanceHistory.removeWhere(
        (PerformanceLogEntry item) => item.key == entry.key,
      );
      _performanceHistory.insert(0, entry);
      notifyListeners();
    });
    _performanceWriteChain = operation.catchError((Object _) {});
    try {
      await operation;
    } on Object {
      _performanceHistoryKeys.remove(entry.key);
    }
  }

  Future<void> _flushBatchQueue({bool force = false}) async {
    if ((!force && _detached) || (_disposed && !force)) return;
    final Future<void>? running = _batchQueueFuture;
    if (running != null) {
      try {
        await running;
      } on Object {
        // 另一个写入失败时，本次也按辅助持久化失败处理。
      }
      if (!force || _batchQueueRequestedRevision <= _batchQueueSavedRevision) {
        return;
      }
    }
    final int revision = _batchQueueRequestedRevision;
    if (revision <= _batchQueueSavedRevision) return;
    final BatchQueueSnapshot snapshot = BatchQueueSnapshot(items: batch.items);
    final Future<void> operation = _batchQueue.save(snapshot);
    _batchQueueFuture = operation;
    try {
      await operation;
      _batchQueueSavedRevision = revision;
    } on Object catch (error) {
      if (!_batchQueueFailureNotified) {
        _batchQueueFailureNotified = true;
        onError('批量任务自动保存失败：$error');
      }
    } finally {
      if (identical(_batchQueueFuture, operation)) _batchQueueFuture = null;
      if (!_detached &&
          !_disposed &&
          _batchQueueRequestedRevision > _batchQueueSavedRevision) {
        _batchQueueTimer?.cancel();
        _batchQueueTimer = Timer(const Duration(milliseconds: 400), () {
          _batchQueueTimer = null;
          unawaited(_flushBatchQueue());
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _detached = true;
      _autosaveTimer?.cancel();
      unawaited(_endSessionOnExit());
      return;
    }
    if (state == AppLifecycleState.resumed && _detached && !_disposed) {
      _detached = false;
      unawaited(_beginSession());
    }
  }

  Future<void> _beginSession() async {
    if (_disposed) return;
    try {
      await _autosave.beginSession();
      _sessionEnded = false;
    } on Object {
      // 会话锁只是恢复提示的辅助信息，写入失败不阻塞主流程。
    }
  }

  Future<void> _endSessionOnExit() async {
    if (_sessionEnded) return;
    _sessionEnded = true;
    _batchQueueTimer?.cancel();
    try {
      await _autosaveFuture;
    } on Object {
      // 当前写入失败也不应阻止结束会话。
    }
    try {
      await _flushBatchQueue(force: true);
    } on Object {
      // 队列快照是辅助数据，写入失败不应阻止结束会话。
    }
    try {
      await _autosave.endSession();
    } on Object {
      // 进程退出时无法保证平台文件操作完成；快照仍保留作下次兜底。
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _detached = true;
    _autosaveTimer?.cancel();
    _batchQueueTimer?.cancel();
    controller.removeListener(_onControllerChanged);
    batch.removeListener(_onBatchChanged);
    live?.removeListener(_onLiveChanged);
    WidgetsBinding.instance.removeObserver(this);
    batch.dispose();
    unawaited(_endSessionOnExit());
    super.dispose();
  }
}
