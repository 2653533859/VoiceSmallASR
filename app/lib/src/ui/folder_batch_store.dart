/// 文件夹批量任务的本地恢复快照。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String kFolderBatchSchema = 'voicesmallasr.folder_batch';
const int kFolderBatchVersion = 1;

class FolderBatchSavedItem {
  const FolderBatchSavedItem({
    required this.path,
    required this.status,
    this.detail,
    this.language,
  });

  final String path;
  final String status;
  final String? detail;
  final String? language;

  factory FolderBatchSavedItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['path'] is! String ||
        value['status'] is! String) {
      throw const FormatException('文件夹批量条目格式无效');
    }
    return FolderBatchSavedItem(
      path: value['path'] as String,
      status: value['status'] as String,
      detail: value['detail'] as String?,
      language: value['language'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'status': status,
    if (detail != null) 'detail': detail,
    if (language != null) 'language': language,
  };
}

class FolderBatchSnapshot {
  const FolderBatchSnapshot({
    required this.directory,
    required this.items,
    required this.translate,
    required this.format,
    required this.conflictPolicy,
    this.language = 'auto',
    this.outputDirectory,
    this.paused = false,
  });

  final String directory;
  final List<FolderBatchSavedItem> items;
  final bool translate;
  final String format;
  final String conflictPolicy;
  final String language;
  final String? outputDirectory;
  final bool paused;

  factory FolderBatchSnapshot.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['schema'] != kFolderBatchSchema ||
        value['version'] != kFolderBatchVersion ||
        value['directory'] is! String ||
        value['items'] is! List<Object?> ||
        value['translate'] is! bool ||
        value['format'] is! String ||
        value['conflict_policy'] is! String) {
      throw const FormatException('文件夹批量快照格式或版本无效');
    }
    final items = <FolderBatchSavedItem>[];
    for (final raw in value['items'] as List<Object?>) {
      try {
        items.add(FolderBatchSavedItem.fromJson(raw));
      } on Object {
        // 单个损坏条目不阻止其他任务恢复。
      }
    }
    return FolderBatchSnapshot(
      directory: value['directory'] as String,
      items: List<FolderBatchSavedItem>.unmodifiable(items),
      translate: value['translate'] as bool,
      format: value['format'] as String,
      conflictPolicy: value['conflict_policy'] as String,
      language: value['language'] as String? ?? 'auto',
      outputDirectory: value['output_directory'] as String?,
      paused: value['paused'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': kFolderBatchSchema,
    'version': kFolderBatchVersion,
    'directory': directory,
    'items': items.map((item) => item.toJson()).toList(),
    'translate': translate,
    'format': format,
    'conflict_policy': conflictPolicy,
    'language': language,
    if (outputDirectory != null) 'output_directory': outputDirectory,
    'paused': paused,
  };
}

class FolderBatchStore {
  const FolderBatchStore({this.rootDirectory});

  final Directory? rootDirectory;

  Future<FolderBatchSnapshot?> load() async {
    final file = await _file(createDirectory: false);
    if (!file.existsSync()) return null;
    try {
      return FolderBatchSnapshot.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } on Object {
      return null;
    }
  }

  Future<void> save(FolderBatchSnapshot snapshot) async {
    final file = await _file(createDirectory: true);
    final content = const JsonEncoder.withIndent('  ')
        .convert(snapshot.toJson());
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString('$content\n', flush: true);
    await temporary.rename(file.path);
  }

  Future<void> clear() async {
    final file = await _file(createDirectory: false);
    final temporary = File('${file.path}.tmp');
    if (file.existsSync()) await file.delete();
    if (temporary.existsSync()) await temporary.delete();
  }

  Future<File> _file({required bool createDirectory}) async {
    final support = rootDirectory ?? await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'batch_queue'));
    if (createDirectory) await directory.create(recursive: true);
    return File(p.join(directory.path, 'folder_queue.json'));
  }
}
