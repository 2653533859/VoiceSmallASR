/// 识别任务的共享排队器。
///
/// 文件转写、当前视频和后台预缓存共用一个识别 worker；这里把优先级
/// 集中管理，避免界面层各自用 busy 标志互相抢占。流式任务通过
/// [TranscriptionTaskLease.pauseRequested] 协作让出 worker。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum TranscriptionTaskPriority {
  live(0),
  currentVideo(1),
  userTask(2),
  backgroundCache(3);

  const TranscriptionTaskPriority(this.rank);

  final int rank;
}

class TranscriptionTaskPreempted implements Exception {
  const TranscriptionTaskPreempted(this.requestedBy);

  final String requestedBy;

  @override
  String toString() => '后台转写已暂停，优先处理：$requestedBy';
}

class TranscriptionTaskLease {
  TranscriptionTaskLease._(this._scheduler, this.priority, this.label);

  final TranscriptionTaskScheduler _scheduler;
  final TranscriptionTaskPriority priority;
  final String label;
  bool _pauseRequested = false;
  bool _released = false;
  String? _pauseReason;

  bool get pauseRequested => _pauseRequested;

  String? get pauseReason => _pauseReason;

  void _requestPause(String reason) {
    _pauseRequested = true;
    _pauseReason = reason;
  }

  void release() {
    if (_released) return;
    _released = true;
    _scheduler._release(this);
  }
}

class TranscriptionTaskScheduler extends ChangeNotifier {
  TranscriptionTaskScheduler({int? capacity})
    : capacity = capacity ?? _defaultCapacity();

  static int _defaultCapacity() {
    // 手机端内存有限 (每个模型 ~240MB)，建议并发 2；桌面端可更高。
    if (Platform.isAndroid || Platform.isIOS) return 2;
    return 4;
  }

  final int capacity;
  final List<_PendingTask> _pending = <_PendingTask>[];
  final List<TranscriptionTaskLease> _activeLeases = <TranscriptionTaskLease>[];
  int _sequence = 0;
  bool _disposed = false;

  List<TranscriptionTaskLease> get activeLeases =>
      List<TranscriptionTaskLease>.unmodifiable(_activeLeases);

  TranscriptionTaskLease? get active =>
      _activeLeases.isEmpty ? null : _activeLeases.first;

  String? get activeLabel => _activeLeases.isEmpty
      ? null
      : _activeLeases.map((TranscriptionTaskLease l) => l.label).join(', ');

  TranscriptionTaskPriority? get activePriority => _activeLeases.isEmpty
      ? null
      : _activeLeases
            .map((TranscriptionTaskLease l) => l.priority)
            .reduce((a, b) => a.rank < b.rank ? a : b);

  List<String> get queuedLabels => List<String>.unmodifiable(
    _pending.map((_PendingTask task) => task.label),
  );

  Future<TranscriptionTaskLease> acquire({
    required TranscriptionTaskPriority priority,
    required String label,
  }) {
    if (_disposed) {
      return Future<TranscriptionTaskLease>.error(StateError('识别任务调度器已关闭'));
    }
    final Completer<TranscriptionTaskLease> completer =
        Completer<TranscriptionTaskLease>();
    _pending.add(
      _PendingTask(
        priority: priority,
        label: label,
        sequence: _sequence++,
        completer: completer,
      ),
    );
    _pending.sort((_PendingTask a, _PendingTask b) {
      final int priorityOrder = a.priority.rank.compareTo(b.priority.rank);
      return priorityOrder != 0
          ? priorityOrder
          : a.sequence.compareTo(b.sequence);
    });

    _checkPreemption();
    _drain();
    notifyListeners();
    return completer.future;
  }

  void _checkPreemption() {
    if (_pending.isEmpty) return;

    final _PendingTask next = _pending.first;
    // 如果槽位已满，尝试抢占优先级最低（rank 最大）且低于 next 优先级的活跃任务。
    if (_activeLeases.length >= capacity) {
      TranscriptionTaskLease? lowestActive;
      for (final TranscriptionTaskLease lease in _activeLeases) {
        if (!lease.pauseRequested && next.priority.rank < lease.priority.rank) {
          if (lowestActive == null ||
              lease.priority.rank > lowestActive.priority.rank) {
            lowestActive = lease;
          }
        }
      }
      lowestActive?._requestPause(next.label);
    }
  }

  void _drain() {
    if (_pending.isEmpty || _disposed || _activeLeases.length >= capacity) {
      return;
    }
    while (_pending.isNotEmpty && _activeLeases.length < capacity) {
      final _PendingTask next = _pending.removeAt(0);
      final TranscriptionTaskLease lease = TranscriptionTaskLease._(
        this,
        next.priority,
        next.label,
      );
      _activeLeases.add(lease);
      next.completer.complete(lease);
    }
    notifyListeners();
  }

  void _release(TranscriptionTaskLease lease) {
    if (_activeLeases.remove(lease)) {
      _checkPreemption();
      _drain();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final List<_PendingTask> pending = List<_PendingTask>.from(_pending);
    _pending.clear();
    for (final _PendingTask task in pending) {
      task.completer.completeError(StateError('识别任务调度器已关闭'));
    }
    _activeLeases.clear();
    super.dispose();
  }
}

class _PendingTask {
  const _PendingTask({
    required this.priority,
    required this.label,
    required this.sequence,
    required this.completer,
  });

  final TranscriptionTaskPriority priority;
  final String label;
  final int sequence;
  final Completer<TranscriptionTaskLease> completer;
}
