/// 性能报告历史记录的持久化。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String kPerformanceLogSchema = 'voicesmallasr.performance_log';
const int kPerformanceLogVersion = 1;

/// 一条可追踪的性能报告历史记录。
class PerformanceLogEntry {
  const PerformanceLogEntry({
    required this.kind,
    required this.generatedAt,
    required this.report,
  });

  final String kind;
  final DateTime generatedAt;
  final Map<String, Object?> report;

  String get key => '$kind:${generatedAt.toUtc().toIso8601String()}';

  String get label => switch (kind) {
    'file' => '文件转写',
    'batch' => '批量转写',
    'live' => '实时字幕',
    _ => kind,
  };

  factory PerformanceLogEntry.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('性能日志条目必须是 JSON 对象');
    }
    final Object? rawKind = value['kind'];
    if (rawKind is! String || rawKind.trim().isEmpty) {
      throw const FormatException('性能日志 kind 必须是非空字符串');
    }
    final Object? rawGeneratedAt = value['generated_at'];
    if (rawGeneratedAt is! String) {
      throw const FormatException('性能日志 generated_at 必须是字符串');
    }
    final DateTime? generatedAt = DateTime.tryParse(rawGeneratedAt);
    if (generatedAt == null) {
      throw const FormatException('性能日志 generated_at 不是有效时间');
    }
    final Object? rawReport = value['report'];
    if (rawReport is! Map<String, dynamic>) {
      throw const FormatException('性能日志 report 必须是 JSON 对象');
    }
    return PerformanceLogEntry(
      kind: rawKind.trim(),
      generatedAt: generatedAt,
      report: Map<String, Object?>.of(rawReport),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'report': report,
  };
}

/// 使用应用私有支持目录保存有限数量的性能历史；测试可注入临时目录。
class PerformanceLogStore {
  PerformanceLogStore({this.rootDirectory, this.maxEntries = 100})
    : assert(maxEntries > 0);

  final Directory? rootDirectory;
  final int maxEntries;
  Future<void> _writeChain = Future<void>.value();

  Future<List<PerformanceLogEntry>> load() async {
    final File file = await _file(createDirectory: false);
    if (!file.existsSync()) return <PerformanceLogEntry>[];
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != kPerformanceLogSchema ||
          decoded['version'] != kPerformanceLogVersion ||
          decoded['entries'] is! List<Object?>) {
        return <PerformanceLogEntry>[];
      }
      final List<PerformanceLogEntry> entries = <PerformanceLogEntry>[];
      for (final Object? raw in decoded['entries'] as List<Object?>) {
        try {
          entries.add(PerformanceLogEntry.fromJson(raw));
        } on Object {
          // 单条历史损坏时跳过，不阻塞其他历史记录的显示。
        }
      }
      return entries.length <= maxEntries
          ? entries
          : entries.sublist(entries.length - maxEntries);
    } on Object {
      return <PerformanceLogEntry>[];
    }
  }

  Future<void> append(PerformanceLogEntry entry) {
    final Future<void> operation = _writeChain.then<void>((_) async {
      final List<PerformanceLogEntry> entries = await load()
        ..removeWhere((PerformanceLogEntry item) => item.key == entry.key);
      entries.add(entry);
      final int first = entries.length > maxEntries
          ? entries.length - maxEntries
          : 0;
      await _save(entries.sublist(first));
    });
    _writeChain = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> clear() {
    final Future<void> operation = _writeChain.then<void>((_) async {
      final File file = await _file(createDirectory: false);
      final File temporary = File('${file.path}.tmp');
      if (file.existsSync()) await file.delete();
      if (temporary.existsSync()) await temporary.delete();
    });
    _writeChain = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _save(List<PerformanceLogEntry> entries) async {
    final File file = await _file(createDirectory: true);
    final Map<String, Object?> snapshot = <String, Object?>{
      'schema': kPerformanceLogSchema,
      'version': kPerformanceLogVersion,
      'entries': entries
          .map((PerformanceLogEntry entry) => entry.toJson())
          .toList(),
    };
    final String content = const JsonEncoder.withIndent('  ').convert(snapshot);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString('$content\n', flush: true);
    await temporary.rename(file.path);
  }

  Future<File> _file({required bool createDirectory}) async {
    final Directory support =
        rootDirectory ?? await getApplicationSupportDirectory();
    final Directory directory = Directory(p.join(support.path, 'performance'));
    if (createDirectory) await directory.create(recursive: true);
    return File(p.join(directory.path, 'history.json'));
  }
}
