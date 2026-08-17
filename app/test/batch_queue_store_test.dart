import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';
import 'package:vsasr_app/src/ui/batch_queue_store.dart';

void main() {
  late Directory root;
  late BatchQueueStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('vsasr_batch_queue_test');
    store = BatchQueueStore(rootDirectory: root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('队列快照 round-trip 保留状态、结果、错误和尝试次数', () async {
    final BatchQueueSnapshot snapshot = BatchQueueSnapshot(
      items: <BatchItem>[
        const BatchItem(path: '/tmp/queued.wav'),
        const BatchItem(
          path: '/tmp/failed.wav',
          status: BatchItemStatus.failed,
          errorText: '解码失败',
          attempts: 2,
        ),
        const BatchItem(
          path: '/tmp/translated.wav',
          status: BatchItemStatus.translated,
          result: TranscriptionResult(
            language: 'en',
            duration: 1,
            segments: <Segment>[
              Segment(
                text: 'hello',
                start: 0,
                end: 1,
                index: 0,
                translation: '你好',
              ),
            ],
          ),
        ),
      ],
    );
    await store.save(snapshot);

    final BatchQueueSnapshot? loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.items, hasLength(3));
    expect(loaded.items[1].errorText, '解码失败');
    expect(loaded.items[1].attempts, 2);
    expect(loaded.items[2].result?.segments.single.translation, '你好');
    expect(loaded.hasRecoverableWork, isTrue);
  });

  test('只包含已完成条目的快照不需要启动恢复', () {
    final BatchQueueSnapshot snapshot = BatchQueueSnapshot(
      items: <BatchItem>[
        const BatchItem(
          path: '/tmp/done.wav',
          status: BatchItemStatus.completed,
        ),
        const BatchItem(
          path: '/tmp/cancelled.wav',
          status: BatchItemStatus.cancelled,
        ),
      ],
    );

    expect(snapshot.hasRecoverableWork, isFalse);
  });

  test('版本错误或 JSON 损坏按没有快照处理', () async {
    await store.save(
      const BatchQueueSnapshot(
        items: <BatchItem>[BatchItem(path: '/tmp/pending.wav')],
      ),
    );
    final File file = File(p.join(root.path, 'batch_queue', 'queue.json'));
    final Map<String, dynamic> document =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    await file.writeAsString(
      jsonEncode(<String, dynamic>{...document, 'version': 999}),
    );
    expect(await store.load(), isNull);

    await file.writeAsString('{not-json');
    expect(await store.load(), isNull);
  });

  test('单个损坏条目不会阻塞其他条目恢复', () async {
    await store.save(
      const BatchQueueSnapshot(
        items: <BatchItem>[BatchItem(path: '/tmp/pending.wav')],
      ),
    );
    final File file = File(p.join(root.path, 'batch_queue', 'queue.json'));
    final Map<String, dynamic> document =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final List<dynamic> items = document['items'] as List<dynamic>;
    items.add(<String, dynamic>{'path': '', 'status': 'queued'});
    items.add(<String, dynamic>{
      'path': '/tmp/invalid-timeline.wav',
      'status': 'completed',
      'result': const TranscriptionResult(
        duration: 1,
        segments: <Segment>[Segment(text: '坏数据', start: 0, end: 0)],
      ).toJson(),
    });
    await file.writeAsString(jsonEncode(document));

    final BatchQueueSnapshot? loaded = await store.load();

    expect(loaded?.items.map((BatchItem item) => item.path), <String>[
      '/tmp/pending.wav',
    ]);
  });

  test('清理快照后不再加载旧队列', () async {
    await store.save(
      const BatchQueueSnapshot(
        items: <BatchItem>[BatchItem(path: '/tmp/pending.wav')],
      ),
    );
    await store.clear();

    expect(await store.load(), isNull);
  });
}
