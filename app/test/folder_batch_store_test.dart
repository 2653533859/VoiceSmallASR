import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/ui/folder_batch_store.dart';

void main() {
  late Directory directory;
  late FolderBatchStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('folder_batch_store_test');
    store = FolderBatchStore(rootDirectory: directory);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('保存、读取和清除文件夹批量快照', () async {
    const snapshot = FolderBatchSnapshot(
      directory: '/media',
      items: [
        FolderBatchSavedItem(
          path: '/media/1.mp4',
          status: 'queued',
          detail: '等待中',
        ),
      ],
      translate: true,
      format: 'srt',
      conflictPolicy: 'skip',
      paused: true,
    );
    await store.save(snapshot);
    final loaded = await store.load();
    expect(loaded?.directory, '/media');
    expect(loaded?.items.single.path, '/media/1.mp4');
    expect(loaded?.paused, isTrue);
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('损坏快照返回空结果', () async {
    final queue = Directory('${directory.path}/batch_queue')..createSync();
    File('${queue.path}/folder_queue.json').writeAsStringSync('{bad json');
    expect(await store.load(), isNull);
  });
}
