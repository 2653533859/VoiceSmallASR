/// 批量处理队列的异常退出恢复快照。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';

const String kBatchQueueSchema = 'voicesmallasr.batch_queue';
const int kBatchQueueVersion = 1;

/// 可持久化的批量条目集合。
class BatchQueueSnapshot {
  const BatchQueueSnapshot({required this.items});

  final List<BatchItem> items;

  /// 只有未完成、失败待重试或进行中的条目才需要启动时恢复。
  bool get hasRecoverableWork => items.any(
    (BatchItem item) => switch (item.status) {
      BatchItemStatus.queued ||
      BatchItemStatus.processing ||
      BatchItemStatus.paused ||
      BatchItemStatus.translating ||
      BatchItemStatus.failed ||
      BatchItemStatus.translationFailed => true,
      BatchItemStatus.completed ||
      BatchItemStatus.translated ||
      BatchItemStatus.cancelled => false,
    },
  );

  factory BatchQueueSnapshot.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('批量队列快照必须是 JSON 对象');
    }
    if (value['schema'] != kBatchQueueSchema ||
        value['version'] != kBatchQueueVersion) {
      throw FormatException(
        '不支持的批量队列快照版本：${value['schema']} / ${value['version']}',
      );
    }
    final Object? rawItems = value['items'];
    if (rawItems is! List<Object?>) {
      throw const FormatException('批量队列 items 必须是 JSON 数组');
    }
    final List<BatchItem> items = <BatchItem>[];
    for (final Object? rawItem in rawItems) {
      try {
        items.add(BatchItem.fromJson(rawItem));
      } on Object {
        // 单个条目损坏时跳过该条目，其他文件仍可恢复。
      }
    }
    return BatchQueueSnapshot(items: List<BatchItem>.unmodifiable(items));
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': kBatchQueueSchema,
    'version': kBatchQueueVersion,
    'items': items.map((BatchItem item) => item.toJson()).toList(),
  };
}

/// 使用应用私有支持目录保存批量队列；测试可注入临时目录。
class BatchQueueStore {
  const BatchQueueStore({this.rootDirectory});

  final Directory? rootDirectory;

  Future<BatchQueueSnapshot?> load() async {
    final File file = await _file(createDirectory: false);
    if (!file.existsSync()) return null;
    try {
      return BatchQueueSnapshot.fromJson(jsonDecode(await file.readAsString()));
    } on Object {
      return null;
    }
  }

  Future<void> save(BatchQueueSnapshot snapshot) async {
    if (snapshot.items.isEmpty) {
      await clear();
      return;
    }
    final File file = await _file(createDirectory: true);
    final String content = const JsonEncoder.withIndent('  ')
        .convert(snapshot.toJson());
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString('$content\n', flush: true);
    await temporary.rename(file.path);
  }

  Future<void> clear() async {
    final File file = await _file(createDirectory: false);
    final File temporary = File('${file.path}.tmp');
    if (file.existsSync()) await file.delete();
    if (temporary.existsSync()) await temporary.delete();
  }

  Future<File> _file({required bool createDirectory}) async {
    final Directory support =
        rootDirectory ?? await getApplicationSupportDirectory();
    final Directory directory = Directory(p.join(support.path, 'batch_queue'));
    if (createDirectory) await directory.create(recursive: true);
    return File(p.join(directory.path, 'queue.json'));
  }
}
