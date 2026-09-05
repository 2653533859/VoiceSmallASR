/// 独立进程长音频资源验收；需要显式指定真实语音文件，不下载模型。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/ui/transcription_task_scheduler.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('真实长音频分块资源验收', () async {
    const String definedAudio = String.fromEnvironment(
      'VSASR_DEVICE_TEST_AUDIO',
    );
    const String definedWorkers = String.fromEnvironment(
      'VSASR_DEVICE_WORKERS',
    );
    const String definedReport = String.fromEnvironment(
      'VSASR_DEVICE_TEST_REPORT',
    );
    final String audio = definedAudio.isNotEmpty
        ? definedAudio
        : Platform.environment['VSASR_DEVICE_TEST_AUDIO'] ?? '';
    final int workers = int.parse(
      definedWorkers.isNotEmpty
          ? definedWorkers
          : Platform.environment['VSASR_DEVICE_WORKERS'] ?? '1',
    );
    final String output = definedReport.isNotEmpty
        ? definedReport
        : Platform.environment['VSASR_DEVICE_TEST_REPORT'] ?? '';
    expect(audio, isNotEmpty, reason: '必须指定 VSASR_DEVICE_TEST_AUDIO');
    expect(File(audio).existsSync(), isTrue, reason: '指定的真实语音文件不存在');
    expect(workers, inInclusiveRange(1, 4));
    expect(output, isNotEmpty, reason: '必须指定 VSASR_DEVICE_TEST_REPORT');
    final TranscriptionTaskScheduler scheduler = TranscriptionTaskScheduler(
      capacity: workers,
    );
    final TranscribeController controller = TranscribeController(
      scheduler: scheduler,
      offlineMode: true,
    );
    final Stopwatch watch = Stopwatch()..start();
    final List<Map<String, int>> memory = <Map<String, int>>[];
    void sampleMemory() => memory.add(<String, int>{
      'elapsed_ms': watch.elapsedMilliseconds,
      'rss_bytes': ProcessInfo.currentRss,
    });
    sampleMemory();
    final Timer sampling = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => sampleMemory(),
    );
    try {
      final results = await Future.wait(
        List.generate(workers, (_) => controller.transcribeFile(audio)),
      );
      sampleMemory();
      final report = <String, Object?>{
        'schema_version': 1,
        'platform': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'workers': workers,
        'input_bytes': await File(audio).length(),
        'status': results.every((value) => value != null)
            ? 'completed'
            : 'failed',
        'quality_verified': false,
        'reports': results.map((value) => value?.report.toJson()).toList(),
        'rss_samples': memory,
        'error': controller.errorText,
      };
      final File target = File(output);
      await target.parent.create(recursive: true);
      await target.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        flush: true,
      );
      for (final result in results) {
        expect(result, isNotNull, reason: controller.errorText);
        expect(result!.result.duration, greaterThan(0));
        expect(result.result.segments, isNotEmpty, reason: '请提供真实含语音的素材');
        expect(result.report.chunkCount, greaterThan(0));
      }
      expect(controller.scheduler.activeLeases, isEmpty);
    } finally {
      sampling.cancel();
      await controller.shutdown();
      scheduler.dispose();
    }
  }, timeout: const Timeout(Duration(hours: 4)));
}
