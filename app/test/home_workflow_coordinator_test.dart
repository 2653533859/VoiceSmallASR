import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/diagnostics/performance_log_store.dart';
import 'package:vsasr_app/src/project/project_file.dart';
import 'package:vsasr_app/src/ui/batch_queue_store.dart';
import 'package:vsasr_app/src/ui/home_workflow_coordinator.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

import 'support/fake_asr.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('vsasr_workflow_test');
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('批量状态变化由首页协调器统一通知', () async {
    final TranscribeController controller = TranscribeController(
      decoder: FakeDecoder(),
      models: ModelManager(root: workspace.path),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => FakeTranscriber(language: config.language),
    );
    final HomeWorkflowCoordinator coordinator = HomeWorkflowCoordinator(
      controller: controller,
      live: null,
      settings: null,
      autosave: FileProjectAutosaveStore(rootDirectory: workspace),
      batchQueue: BatchQueueStore(rootDirectory: workspace),
      performanceLog: PerformanceLogStore(rootDirectory: workspace),
      onError: (_) {},
    )..init();
    addTearDown(() async {
      coordinator.dispose();
      await controller.shutdown();
    });

    int notifications = 0;
    coordinator.addListener(() => notifications++);
    coordinator.batch.enqueue(<String>['/tmp/one.wav', '/tmp/two.wav']);

    expect(coordinator.batch.items, hasLength(2));
    expect(notifications, greaterThanOrEqualTo(1));
    expect(coordinator.batchBusy, isFalse);
  });
}
