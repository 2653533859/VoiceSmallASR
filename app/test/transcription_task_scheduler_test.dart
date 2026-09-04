import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/ui/transcription_task_scheduler.dart';

void main() {
  test('高优先级任务会请求后台任务让行并优先获得 lease', () async {
    final TranscriptionTaskScheduler scheduler = TranscriptionTaskScheduler(
      capacity: 1,
    );
    addTearDown(scheduler.dispose);

    final TranscriptionTaskLease background = await scheduler.acquire(
      priority: TranscriptionTaskPriority.backgroundCache,
      label: '后台视频',
    );
    final Future<TranscriptionTaskLease> liveFuture = scheduler.acquire(
      priority: TranscriptionTaskPriority.live,
      label: '实时字幕',
    );

    expect(background.pauseRequested, isTrue);
    expect(background.pauseReason, '实时字幕');
    expect(scheduler.queuedLabels, <String>['实时字幕']);

    background.release();
    final TranscriptionTaskLease live = await liveFuture;
    expect(live.priority, TranscriptionTaskPriority.live);
    expect(scheduler.activeLabel, '实时字幕');
    live.release();
    expect(scheduler.active, isNull);
  });

  test('相同优先级按提交顺序执行', () async {
    final TranscriptionTaskScheduler scheduler = TranscriptionTaskScheduler(
      capacity: 1,
    );
    addTearDown(scheduler.dispose);

    final TranscriptionTaskLease first = await scheduler.acquire(
      priority: TranscriptionTaskPriority.currentVideo,
      label: '当前视频',
    );
    final Future<TranscriptionTaskLease> secondFuture = scheduler.acquire(
      priority: TranscriptionTaskPriority.currentVideo,
      label: '下一个视频',
    );
    final Future<TranscriptionTaskLease> backgroundFuture = scheduler.acquire(
      priority: TranscriptionTaskPriority.backgroundCache,
      label: '预缓存',
    );

    first.release();
    final TranscriptionTaskLease second = await secondFuture;
    expect(second.label, '下一个视频');
    second.release();
    final TranscriptionTaskLease background = await backgroundFuture;
    expect(background.label, '预缓存');
    background.release();
  });

  test('容量未满时允许并行，满载后续任务才排队', () async {
    final TranscriptionTaskScheduler scheduler = TranscriptionTaskScheduler(
      capacity: 2,
    );
    addTearDown(scheduler.dispose);

    final TranscriptionTaskLease first = await scheduler.acquire(
      priority: TranscriptionTaskPriority.userTask,
      label: '文件一',
    );
    final TranscriptionTaskLease second = await scheduler.acquire(
      priority: TranscriptionTaskPriority.userTask,
      label: '文件二',
    );
    final Future<TranscriptionTaskLease> thirdFuture = scheduler.acquire(
      priority: TranscriptionTaskPriority.userTask,
      label: '文件三',
    );

    expect(scheduler.activeLeases, hasLength(2));
    expect(scheduler.queuedLabels, <String>['文件三']);
    first.release();

    final TranscriptionTaskLease third = await thirdFuture;
    expect(scheduler.activeLeases, hasLength(2));
    second.release();
    third.release();
  });
}
