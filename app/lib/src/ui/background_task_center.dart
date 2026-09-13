/// 首页后台任务中心：汇总文件、批量、实时与识别资源状态。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';
import 'package:vsasr_app/src/ui/live_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

typedef BackgroundTaskActionCallback = Future<void> Function();

class BackgroundTaskAction {
  const BackgroundTaskAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final BackgroundTaskActionCallback onPressed;
}

class RegisteredBackgroundTask {
  const RegisteredBackgroundTask({
    required this.id,
    required this.title,
    required this.detail,
    required this.icon,
    this.progress,
    this.indeterminate = false,
    this.actions = const <BackgroundTaskAction>[],
  });

  final String id;
  final String title;
  final String detail;
  final IconData icon;
  final double? progress;
  final bool indeterminate;
  final List<BackgroundTaskAction> actions;
}

class BackgroundTaskFailure {
  const BackgroundTaskFailure({
    required this.title,
    required this.message,
    required this.occurredAt,
    this.fileName,
  });

  final String title;
  final String message;
  final DateTime occurredAt;
  final String? fileName;
}

/// 页面局部后台任务的轻量注册表，不持有页面之外的业务状态。
class BackgroundTaskRegistry extends ChangeNotifier {
  static const int maxFailureCount = 10;
  final Map<String, RegisteredBackgroundTask> _tasks =
      <String, RegisteredBackgroundTask>{};
  final List<BackgroundTaskFailure> _failures = <BackgroundTaskFailure>[];
  bool _disposed = false;

  List<RegisteredBackgroundTask> get tasks =>
      List<RegisteredBackgroundTask>.unmodifiable(_tasks.values);
  List<BackgroundTaskFailure> get failures =>
      List<BackgroundTaskFailure>.unmodifiable(_failures);

  void upsert(RegisteredBackgroundTask task) {
    if (_disposed) return;
    _tasks[task.id] = task;
    notifyListeners();
  }

  void remove(String id) {
    if (_disposed) return;
    if (_tasks.remove(id) != null) notifyListeners();
  }

  void recordFailure({
    required String title,
    required String message,
    String? filePath,
    DateTime? occurredAt,
  }) {
    if (_disposed) return;
    _failures.insert(
      0,
      BackgroundTaskFailure(
        title: title,
        message: sanitizeTaskFailureMessage(message),
        occurredAt: occurredAt ?? DateTime.now(),
        fileName: filePath == null ? null : p.basename(filePath),
      ),
    );
    if (_failures.length > maxFailureCount) {
      _failures.removeRange(maxFailureCount, _failures.length);
    }
    notifyListeners();
  }

  void clearFailures() {
    if (_disposed || _failures.isEmpty) return;
    _failures.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tasks.clear();
    _failures.clear();
    super.dispose();
  }
}

class BackgroundTaskCenterButton extends StatelessWidget {
  const BackgroundTaskCenterButton({
    super.key,
    required this.controller,
    required this.batch,
    required this.live,
    this.registry,
    required this.onPressed,
  });

  final TranscribeController controller;
  final BatchTranscriptionController batch;
  final LiveController? live;
  final BackgroundTaskRegistry? registry;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller,
        batch,
        controller.scheduler,
        ?live,
        ?registry,
      ]),
      builder: (BuildContext context, Widget? _) {
        final int count = backgroundTaskCount(
          controller: controller,
          batch: batch,
          live: live,
          registry: registry,
        );
        final Widget icon = const Icon(Icons.task_alt_outlined, size: 18);
        return IconButton(
          key: const Key('backgroundTaskCenter'),
          tooltip: count == 0 ? '任务中心' : '任务中心（$count）',
          onPressed: onPressed,
          icon: count == 0 ? icon : Badge(label: Text('$count'), child: icon),
        );
      },
    );
  }
}

int backgroundTaskCount({
  required TranscribeController controller,
  required BatchTranscriptionController batch,
  required LiveController? live,
  BackgroundTaskRegistry? registry,
}) {
  int count = 0;
  final bool batchPending =
      batch.running ||
      batch.paused ||
      batch.items.any(
        (BatchItem item) =>
            item.status == BatchItemStatus.queued ||
            item.status == BatchItemStatus.processing ||
            item.status == BatchItemStatus.translating ||
            item.status == BatchItemStatus.failed ||
            item.status == BatchItemStatus.translationFailed,
      );
  if (batchPending) count++;
  if (controller.busy && !batch.running) count++;
  if (live?.busy ?? false) count++;
  count += controller.scheduler.queuedLabels.length;
  count += registry?.tasks.length ?? 0;
  return count;
}

class BackgroundTaskCenterDialog extends StatelessWidget {
  const BackgroundTaskCenterDialog({
    super.key,
    required this.controller,
    required this.batch,
    required this.live,
    this.registry,
    required this.onOpenBatch,
  });

  final TranscribeController controller;
  final BatchTranscriptionController batch;
  final LiveController? live;
  final BackgroundTaskRegistry? registry;
  final Future<void> Function() onOpenBatch;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: <Widget>[
          Icon(Icons.task_alt_outlined),
          SizedBox(width: 10),
          Text('任务中心'),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            controller,
            batch,
            controller.scheduler,
            ?live,
            ?registry,
          ]),
          builder: (BuildContext context, Widget? _) {
            final List<Widget> tasks = _buildTasks(context);
            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 560),
              child: tasks.isEmpty
                  ? const _EmptyTaskCenter()
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, int index) => tasks[index],
                    ),
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('closeBackgroundTaskCenter'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  List<Widget> _buildTasks(BuildContext context) {
    final List<Widget> tasks = <Widget>[];
    for (final RegisteredBackgroundTask task
        in registry?.tasks ?? const <RegisteredBackgroundTask>[]) {
      tasks.add(
        _TaskCard(
          key: Key('registeredBackgroundTask-${task.id}'),
          icon: task.icon,
          title: task.title,
          detail: task.detail,
          progress: task.progress,
          indeterminate: task.indeterminate,
          actions: task.actions
              .map(
                (BackgroundTaskAction action) => TextButton.icon(
                  onPressed: () => unawaited(
                    _runAction(context, action.onPressed, '${action.label}失败'),
                  ),
                  icon: Icon(action.icon),
                  label: Text(action.label),
                ),
              )
              .toList(growable: false),
        ),
      );
    }
    final bool batchVisible =
        batch.running ||
        batch.paused ||
        batch.items.any(
          (BatchItem item) =>
              item.status == BatchItemStatus.queued ||
              item.status == BatchItemStatus.processing ||
              item.status == BatchItemStatus.translating ||
              item.status == BatchItemStatus.failed ||
              item.status == BatchItemStatus.translationFailed,
        );

    if (controller.busy && !batch.running) {
      tasks.add(
        _TaskCard(
          key: const Key('taskCenterCurrentTask'),
          icon: _jobIcon(controller.stage),
          title: _jobTitle(controller.stage),
          detail: _taskDetail(controller.filePath, controller.statusText),
          progress: controller.progress,
          indeterminate: controller.progress == null,
          actions: <Widget>[
            TextButton.icon(
              key: const Key('taskCenterCancelCurrent'),
              onPressed: () => unawaited(
                _runAction(context, controller.cancelCurrentTask, '取消当前任务失败'),
              ),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('取消'),
            ),
          ],
        ),
      );
    }

    if (batchVisible) {
      final BatchItem? current = batch.currentIndex == null
          ? null
          : batch.items[batch.currentIndex!];
      final int failed = batch.items
          .where(
            (BatchItem item) =>
                item.status == BatchItemStatus.failed ||
                item.status == BatchItemStatus.translationFailed,
          )
          .length;
      final String state = batch.translating
          ? '正在翻译'
          : batch.running
          ? '正在处理'
          : batch.paused
          ? '已暂停'
          : '等待开始';
      final String detail = <String>[
        '$state · 已完成 ${batch.completedCount}/${batch.items.length}',
        if (current != null) p.basename(current.path),
        if (failed > 0) '$failed 个失败条目',
      ].join('\n');
      tasks.add(
        _TaskCard(
          key: const Key('taskCenterBatchTask'),
          icon: batch.translating ? Icons.translate : Icons.library_music,
          title: batch.translating ? '批量翻译' : '批量处理',
          detail: detail,
          progress: current?.progress,
          indeterminate: batch.running && current?.progress == null,
          actions: <Widget>[
            TextButton.icon(
              key: const Key('taskCenterOpenBatch'),
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(onOpenBatch());
              },
              icon: const Icon(Icons.open_in_new),
              label: Text(failed > 0 ? '查看并重试' : '查看'),
            ),
            if (batch.running && !batch.translating)
              TextButton.icon(
                key: const Key('taskCenterPauseBatch'),
                onPressed: batch.pause,
                icon: const Icon(Icons.pause),
                label: const Text('完成当前项后暂停'),
              ),
            if (batch.running || batch.paused)
              TextButton.icon(
                key: const Key('taskCenterCancelBatch'),
                onPressed: () =>
                    unawaited(_runAction(context, batch.cancel, '取消批量任务失败')),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('取消'),
              ),
          ],
        ),
      );
    }

    final LiveController? liveController = live;
    if (liveController?.busy ?? false) {
      tasks.add(
        _TaskCard(
          key: const Key('taskCenterLiveTask'),
          icon: Icons.mic,
          title: '实时字幕',
          detail: liveController!.statusText,
          indeterminate: liveController.stage != LiveStage.recording,
          actions: <Widget>[
            if (liveController.recording)
              TextButton.icon(
                key: const Key('taskCenterStopLive'),
                onPressed: () => unawaited(
                  _runAction(context, liveController.stop, '停止实时字幕失败'),
                ),
                icon: const Icon(Icons.stop),
                label: const Text('停止'),
              ),
          ],
        ),
      );
    }

    final active = controller.scheduler.activeLeases;
    final queued = controller.scheduler.queuedLabels;
    if (active.isNotEmpty || queued.isNotEmpty) {
      tasks.add(
        _TaskCard(
          key: const Key('taskCenterResourceStatus'),
          icon: Icons.memory,
          title: '识别资源',
          detail: <String>[
            '运行中 ${active.length}/${controller.scheduler.capacity}',
            if (active.isNotEmpty)
              '正在处理：${active.map((lease) => lease.label).join('、')}',
            if (queued.isNotEmpty) '等待队列：${queued.join('、')}',
          ].join('\n'),
        ),
      );
    }
    final List<BackgroundTaskFailure> failures =
        registry?.failures ?? const <BackgroundTaskFailure>[];
    if (failures.isNotEmpty) {
      tasks.add(
        _TaskCard(
          key: const Key('taskCenterRecentFailures'),
          icon: Icons.error_outline,
          title: '最近失败任务',
          detail: failures.map(_formatFailure).join('\n'),
          actions: <Widget>[
            TextButton.icon(
              key: const Key('taskCenterClearFailures'),
              onPressed: registry!.clearFailures,
              icon: const Icon(Icons.delete_outline),
              label: const Text('清除记录'),
            ),
          ],
        ),
      );
    }
    return tasks;
  }

  Future<void> _runAction(
    BuildContext context,
    Future<void> Function() action,
    String failureLabel,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$failureLabel：$error')));
    }
  }
}

String sanitizeTaskFailureMessage(String message) {
  String value = message.split(RegExp(r'[\r\n]')).first.trim();
  value = value.replaceAll(
    RegExp(r'Bearer\s+\S+', caseSensitive: false),
    'Bearer [已隐藏]',
  );
  value = value.replaceAll(RegExp(r'sk-[A-Za-z0-9_-]{8,}'), '[API Key 已隐藏]');
  value = value.replaceAll(
    RegExp(r'https?://\S+', caseSensitive: false),
    '[网络地址已隐藏]',
  );
  value = value.replaceAll(RegExp(r'(?:/[A-Za-z0-9._~+ -]+){2,}'), '[路径已隐藏]');
  value = value.replaceAll(
    RegExp(r'[A-Za-z]:\\(?:[^\\\s]+\\)*[^\\\s]+'),
    '[路径已隐藏]',
  );
  if (value.isEmpty) return '未提供错误详情';
  return value.length <= 240 ? value : '${value.substring(0, 240)}…';
}

String _formatFailure(BackgroundTaskFailure failure) {
  final DateTime time = failure.occurredAt.toLocal();
  final String hour = time.hour.toString().padLeft(2, '0');
  final String minute = time.minute.toString().padLeft(2, '0');
  return <String>[
    '$hour:$minute ${failure.title}',
    if (failure.fileName != null) failure.fileName!,
    failure.message,
  ].join(' · ');
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.progress,
    this.indeterminate = false,
    this.actions = const <Widget>[],
  });

  final IconData icon;
  final String title;
  final String detail;
  final double? progress;
  final bool indeterminate;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 3),
                      Text(detail),
                    ],
                  ),
                ),
              ],
            ),
            if (progress != null || indeterminate) ...<Widget>[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progress),
            ],
            if (actions.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(spacing: 4, children: actions),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyTaskCenter extends StatelessWidget {
  const _EmptyTaskCenter();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 44),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.task_alt, size: 42),
          SizedBox(height: 12),
          Text('当前没有后台任务'),
          SizedBox(height: 4),
          Text('识别、翻译和批量处理进度会显示在这里'),
        ],
      ),
    );
  }
}

String _taskDetail(String? path, String status) => <String>[
  if (path != null && path.trim().isNotEmpty) p.basename(path),
  if (status.trim().isNotEmpty) status,
].join('\n');

String _jobTitle(JobStage stage) => switch (stage) {
  JobStage.checkingModel => '检查识别模型',
  JobStage.preparingModel => '准备识别模型',
  JobStage.decoding => '解码媒体',
  JobStage.transcribing => '字幕识别',
  JobStage.translating => '字幕翻译',
  JobStage.diarizing => '说话人分析',
  JobStage.managingModel => '管理识别模型',
  JobStage.idle => '文件任务',
};

IconData _jobIcon(JobStage stage) => switch (stage) {
  JobStage.translating => Icons.translate,
  JobStage.diarizing => Icons.record_voice_over,
  JobStage.preparingModel ||
  JobStage.checkingModel ||
  JobStage.managingModel => Icons.model_training,
  JobStage.decoding => Icons.audio_file,
  JobStage.transcribing => Icons.subtitles,
  JobStage.idle => Icons.task_alt,
};
