import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/diagnostics/performance_log_store.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('vsasr_perf_log_test'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  PerformanceLogEntry entry(String kind, int seconds) => PerformanceLogEntry(
    kind: kind,
    generatedAt: DateTime.utc(2026, 8, 17, 12, 0, seconds),
    report: <String, Object?>{
      'generated_at': DateTime.utc(2026, 8, 17, 12, 0, seconds)
          .toIso8601String(),
      'elapsed_ms': seconds * 100,
    },
  );

  test('追加后可跨实例读取，按上限保留最新记录并能清空', () async {
    final PerformanceLogStore store = PerformanceLogStore(
      rootDirectory: root,
      maxEntries: 2,
    );
    await store.append(entry('file', 1));
    await store.append(entry('batch', 2));
    await store.append(entry('live', 3));

    final List<PerformanceLogEntry> loaded = await PerformanceLogStore(
      rootDirectory: root,
      maxEntries: 2,
    ).load();
    expect(loaded.map((PerformanceLogEntry value) => value.kind), <String>[
      'batch',
      'live',
    ]);

    await store.clear();
    expect(await store.load(), isEmpty);
  });

  test('损坏的单条记录不会阻塞其他记录读取', () async {
    final PerformanceLogStore store = PerformanceLogStore(rootDirectory: root);
    await store.append(entry('file', 1));
    await store.append(entry('live', 2));
    final File file = File('${root.path}/performance/history.json');
    final String content = await file.readAsString();
    await file.writeAsString(
      content.replaceFirst('"kind": "file"', '"kind": 42'),
    );

    final List<PerformanceLogEntry> loaded = await store.load();
    expect(loaded.map((PerformanceLogEntry value) => value.kind), <String>[
      'live',
    ]);
  });
}
