/// 识别任务的共享排队器。
///
/// 文件转写、当前视频和后台预缓存共用一个识别 worker；这里把优先级
/// 集中管理，避免界面层各自用 busy 标志互相抢占。流式任务通过
/// [TranscriptionTaskLease.pauseRequested] 协作让出 worker。
library;

import 'dart:async';

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
  final List<_PendingTask> _pending = <_PendingTask>[];
  TranscriptionTaskLease? _active;
  int _sequence = 0;
  bool _disposed = false;

  TranscriptionTaskLease? get active => _active;

  String? get activeLabel => _active?.label;

  TranscriptionTaskPriority? get activePriority => _active?.priority;

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
    final TranscriptionTaskLease? active = _active;
    if (active != null && priority.rank < active.priority.rank) {
      active._requestPause(label);
    }
    _drain();
    notifyListeners();
    return completer.future;
  }

  void _drain() {
    if (_active != null || _pending.isEmpty || _disposed) return;
    final _PendingTask next = _pending.removeAt(0);
    final TranscriptionTaskLease lease = TranscriptionTaskLease._(
      this,
      next.priority,
      next.label,
    );
    _active = lease;
    next.completer.complete(lease);
    notifyListeners();
  }

  void _release(TranscriptionTaskLease lease) {
    if (!identical(_active, lease)) return;
    _active = null;
    _drain();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final List<_PendingTask> pending = List<_PendingTask>.from(_pending);
    _pending.clear();
    for (final _PendingTask task in pending) {
      task.completer.completeError(StateError('识别任务调度器已关闭'));
    }
    _active = null;
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
