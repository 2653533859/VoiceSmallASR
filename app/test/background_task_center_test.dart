import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/ui/background_task_center.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

import 'support/fake_asr.dart';

void main() {
  test('失败记录脱敏并限制为最近十条', () {
    final BackgroundTaskRegistry registry = BackgroundTaskRegistry();
    addTearDown(registry.dispose);
    for (int index = 0; index < 12; index++) {
      registry.recordFailure(
        title: '翻译失败 $index',
        message: 'Bearer secret-token sk-1234567890 https://example.com/v1?q=secret /Users/name/private/file.json',
        filePath: '/Users/name/videos/movie$index.mp4',
        occurredAt: DateTime(2026, 9, 12, 10, index),
      );
    }

    expect(registry.failures, hasLength(10));
    expect(registry.failures.first.title, '翻译失败 11');
    expect(registry.failures.first.fileName, 'movie11.mp4');
    expect(registry.failures.first.message, isNot(contains('secret')));
    expect(registry.failures.first.message, isNot(contains('/Users')));
    expect(registry.failures.first.message, contains('[API Key 已隐藏]'));
  });

  testWidgets('任务中心显示页面注册任务并执行操作', (WidgetTester tester) async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'registered_task_center_test',
    );
    writeFakeModel(workspace.path);
    final TranscribeController controller = TranscribeController(
      decoder: FakeDecoder(),
      models: ModelManager(root: workspace.path),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => FakeTranscriber(language: config.language),
    );
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: controller,
    );
    final BackgroundTaskRegistry registry = BackgroundTaskRegistry();
    bool cancelled = false;
    registry.upsert(
      RegisteredBackgroundTask(
        id: 'translation',
        title: '视频字幕翻译',
        detail: 'movie.mp4',
        icon: Icons.translate,
        progress: 0.5,
        actions: <BackgroundTaskAction>[
          BackgroundTaskAction(
            label: '取消',
            icon: Icons.stop,
            onPressed: () async => cancelled = true,
          ),
        ],
      ),
    );
    addTearDown(() async {
      registry.dispose();
      batch.dispose();
      await controller.shutdown();
      controller.dispose();
      workspace.deleteSync(recursive: true);
    });

    expect(
      backgroundTaskCount(
        controller: controller,
        batch: batch,
        live: null,
        registry: registry,
      ),
      1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => BackgroundTaskCenterDialog(
                  controller: controller,
                  batch: batch,
                  live: null,
                  registry: registry,
                  onOpenBatch: () async {},
                ),
              ),
              child: const Text('打开任务中心'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开任务中心'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('registeredBackgroundTask-translation')),
      findsOneWidget,
    );
    expect(find.text('movie.mp4'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(cancelled, isTrue);

    registry.recordFailure(
      title: '视频字幕翻译',
      message: '请求超时',
      filePath: '/private/movie.mp4',
    );
    registry.remove('translation');
    await tester.pump();
    expect(find.byKey(const Key('taskCenterRecentFailures')), findsOneWidget);
    expect(find.textContaining('movie.mp4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('taskCenterClearFailures')));
    await tester.pump();
    expect(find.text('当前没有后台任务'), findsOneWidget);
  });

  testWidgets('任务中心汇总批量队列并可进入详情', (WidgetTester tester) async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'task_center_test',
    );
    writeFakeModel(workspace.path);
    final TranscribeController controller = TranscribeController(
      decoder: FakeDecoder(),
      models: ModelManager(root: workspace.path),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => FakeTranscriber(language: config.language),
    );
    final BatchTranscriptionController batch = BatchTranscriptionController(
      transcriber: controller,
    )..enqueue(<String>['/tmp/one.mp4', '/tmp/two.mp4']);
    bool opened = false;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      batch.dispose();
      await controller.shutdown();
      controller.dispose();
      workspace.deleteSync(recursive: true);
    });

    expect(
      backgroundTaskCount(controller: controller, batch: batch, live: null),
      1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => BackgroundTaskCenterDialog(
                  controller: controller,
                  batch: batch,
                  live: null,
                  onOpenBatch: () async => opened = true,
                ),
              ),
              child: const Text('打开任务中心'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开任务中心'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('taskCenterBatchTask')), findsOneWidget);
    expect(find.text('等待开始 · 已完成 0/2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('taskCenterOpenBatch')));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(find.text('任务中心'), findsNothing);
  });
}
