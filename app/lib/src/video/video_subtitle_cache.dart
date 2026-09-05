/// 视频播放列表的本地字幕缓存。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

const String kVideoSubtitleCacheDirectoryName = 'video_subtitles';
const String kVideoSubtitleCacheSchema = 'voicesmallasr.video_subtitle_cache';
const int kVideoSubtitleCacheVersion = 2;
const int kDefaultVideoSubtitleCacheMaxBytes = 2 * 1024 * 1024 * 1024;

class VideoSubtitleCacheEntry {
  const VideoSubtitleCacheEntry({
    required this.mediaPath,
    required this.jsonPath,
    required this.srtPath,
    required this.checkpointPath,
    required this.bytes,
    required this.updatedAt,
    required this.lastAccessedAt,
    required this.isValid,
    required this.isComplete,
    required this.mediaExists,
    required this.mediaMatches,
    required this.configurationMatches,
  });

  final String mediaPath;
  final String jsonPath;
  final String srtPath;
  final String checkpointPath;
  final int bytes;
  final DateTime updatedAt;
  final DateTime lastAccessedAt;
  final bool isValid;
  final bool isComplete;
  final bool mediaExists;
  final bool mediaMatches;
  final bool configurationMatches;
}

class VideoSubtitleCacheSummary {
  const VideoSubtitleCacheSummary({required this.entries, required this.bytes});

  final List<VideoSubtitleCacheEntry> entries;
  final int bytes;
}

class VideoSubtitleCacheCleanupReport {
  const VideoSubtitleCacheCleanupReport({
    required this.removedEntries,
    required this.removedBytes,
    required this.skippedEntries,
  });

  final int removedEntries;
  final int removedBytes;
  final int skippedEntries;
}

class VideoSubtitleCheckpoint {
  const VideoSubtitleCheckpoint({
    required this.result,
    required this.processedSamples,
    required this.updatedAt,
  });

  final TranscriptionResult result;
  final int processedSamples;
  final DateTime updatedAt;
}

class VideoSubtitleCache {
  const VideoSubtitleCache({this.rootDirectory});

  final Directory? rootDirectory;

  Future<String> directoryPath({bool create = false}) async {
    final Directory support =
        rootDirectory ?? await getApplicationSupportDirectory();
    final Directory directory = Directory(
      p.join(support.path, kVideoSubtitleCacheDirectoryName),
    );
    if (create) await directory.create(recursive: true);
    return directory.path;
  }

  Future<TranscriptionResult?> read(
    String mediaPath, {
    String configurationScope = '',
  }) async {
    final File media = File(mediaPath);
    if (!await media.exists()) return null;
    final File cacheFile = await _jsonFile(mediaPath, createDirectory: false);
    if (!await cacheFile.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await cacheFile.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != kVideoSubtitleCacheSchema ||
          decoded['version'] != kVideoSubtitleCacheVersion ||
          decoded['media_path'] != p.normalize(mediaPath) ||
          decoded['configuration_scope'] != configurationScope) {
        return null;
      }
      final FileStat stat = await media.stat();
      if (decoded['media_size'] != stat.size ||
          decoded['media_modified_ms'] !=
              stat.modified.millisecondsSinceEpoch) {
        return null;
      }
      final TranscriptionResult result = TranscriptionResult.fromJson(
        decoded['result'],
      );
      ensureValidSubtitleTimeline(result.segments, duration: result.duration);
      try {
        await cacheFile.setLastModified(DateTime.now());
      } on Object {
        // 最近使用时间只是 LRU 提示，写入失败不应使有效缓存变成未命中。
      }
      return result;
    } on Object {
      return null;
    }
  }

  /// 读取上次异常退出时留下的未完成字幕检查点。
  Future<VideoSubtitleCheckpoint?> readCheckpoint(
    String mediaPath, {
    String configurationScope = '',
  }) async {
    final File checkpointFile = await _checkpointFile(
      mediaPath,
      createDirectory: false,
    );
    if (!await checkpointFile.exists()) return null;
    try {
      final File media = File(mediaPath);
      final Object? decoded = jsonDecode(await checkpointFile.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != kVideoSubtitleCacheSchema ||
          decoded['version'] != kVideoSubtitleCacheVersion ||
          decoded['complete'] != false ||
          decoded['media_path'] != p.normalize(mediaPath) ||
          decoded['configuration_scope'] != configurationScope) {
        return null;
      }
      final FileStat stat = await media.stat();
      if (decoded['media_size'] != stat.size ||
          decoded['media_modified_ms'] !=
              stat.modified.millisecondsSinceEpoch) {
        return null;
      }
      final Object? rawSamples = decoded['processed_samples'];
      if (rawSamples is! int || rawSamples < 0) return null;
      final TranscriptionResult result = TranscriptionResult.fromJson(
        decoded['result'],
      );
      ensureValidSubtitleTimeline(result.segments, duration: result.duration);
      if (result.duration <= 0 && rawSamples > 0) return null;
      final Object? rawUpdatedAt = decoded['updated_at'];
      final DateTime? updatedAt = rawUpdatedAt is String
          ? DateTime.tryParse(rawUpdatedAt)
          : null;
      if (updatedAt == null) return null;
      try {
        await checkpointFile.setLastModified(DateTime.now());
      } on Object {
        // 检查点的访问时间只是清理排序提示。
      }
      return VideoSubtitleCheckpoint(
        result: result,
        processedSamples: rawSamples,
        updatedAt: updatedAt,
      );
    } on Object {
      return null;
    }
  }

  /// 保存未完成转写的检查点；完成态字幕写入时会清理它。
  Future<void> writeCheckpoint(
    String mediaPath,
    TranscriptionResult result, {
    required int processedSamples,
    String configurationScope = '',
  }) async {
    if (processedSamples < 0) {
      throw ArgumentError.value(processedSamples, 'processedSamples', '不能小于 0');
    }
    ensureValidSubtitleTimeline(result.segments, duration: result.duration);
    final File media = File(mediaPath);
    if (!await media.exists()) throw StateError('视频文件不存在，无法保存字幕检查点');
    final FileStat stat = await media.stat();
    final File checkpointFile = await _checkpointFile(
      mediaPath,
      createDirectory: true,
    );
    final String content = const JsonEncoder.withIndent(' ')
        .convert(<String, Object?>{
          'schema': kVideoSubtitleCacheSchema,
          'version': kVideoSubtitleCacheVersion,
          'complete': false,
          'media_path': p.normalize(mediaPath),
          'configuration_scope': configurationScope,
          'media_size': stat.size,
          'media_modified_ms': stat.modified.millisecondsSinceEpoch,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'processed_samples': processedSamples,
          'result': result.toJson(),
        });
    await _atomicWrite(checkpointFile, '$content\n');
  }

  /// 保存结构化 JSON，并同时生成一个可直接使用的同名 SRT 文件。
  Future<String> write(
    String mediaPath,
    TranscriptionResult result, {
    String configurationScope = '',
  }) async {
    ensureValidSubtitleTimeline(result.segments, duration: result.duration);
    final File media = File(mediaPath);
    if (!await media.exists()) throw StateError('视频文件不存在，无法缓存字幕');
    final FileStat stat = await media.stat();
    final File jsonFile = await _jsonFile(mediaPath, createDirectory: true);
    final String content = const JsonEncoder.withIndent(' ')
        .convert(<String, Object?>{
          'schema': kVideoSubtitleCacheSchema,
          'version': kVideoSubtitleCacheVersion,
          'media_path': p.normalize(mediaPath),
          'configuration_scope': configurationScope,
          'media_size': stat.size,
          'media_modified_ms': stat.modified.millisecondsSinceEpoch,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'result': result.toJson(),
        });
    await _atomicWrite(jsonFile, '$content\n');
    final File srtFile = File(p.setExtension(jsonFile.path, '.srt'));
    await _atomicWrite(srtFile, renderSubtitles(result, 'srt'));
    final File checkpointFile = await _checkpointFile(
      mediaPath,
      createDirectory: false,
    );
    if (await checkpointFile.exists()) await checkpointFile.delete();
    return srtFile.path;
  }

  /// 列出缓存文件并校验元数据；损坏或原视频已删除的条目也会返回，供用户清理。
  Future<VideoSubtitleCacheSummary> inspect({
    String? configurationScope,
  }) async {
    final Directory directory = Directory(await directoryPath(create: false));
    if (!await directory.exists()) {
      return const VideoSubtitleCacheSummary(
        entries: <VideoSubtitleCacheEntry>[],
        bytes: 0,
      );
    }
    final Set<String> jsonPaths = <String>{};
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.json')) {
        jsonPaths.add(entity.path);
      } else if (entity.path.endsWith('.json.checkpoint')) {
        jsonPaths.add(
          entity.path.substring(0, entity.path.length - '.checkpoint'.length),
        );
      }
    }
    final List<VideoSubtitleCacheEntry> entries = <VideoSubtitleCacheEntry>[];
    for (final String jsonPath in jsonPaths) {
      entries.add(
        await _inspectFile(
          File(jsonPath),
          configurationScope: configurationScope,
        ),
      );
    }
    entries.sort(
      (VideoSubtitleCacheEntry left, VideoSubtitleCacheEntry right) =>
          right.lastAccessedAt.compareTo(left.lastAccessedAt),
    );
    return VideoSubtitleCacheSummary(
      entries: List<VideoSubtitleCacheEntry>.unmodifiable(entries),
      bytes: entries.fold<int>(
        0,
        (int sum, VideoSubtitleCacheEntry entry) => sum + entry.bytes,
      ),
    );
  }

  /// 删除单个媒体的完整缓存。受保护的媒体（当前播放或正在检查点写入）会跳过。
  Future<VideoSubtitleCacheCleanupReport> deleteMedia(
    String mediaPath, {
    Set<String> protectedMediaPaths = const <String>{},
  }) async {
    final String normalized = p.normalize(mediaPath);
    if (protectedMediaPaths.map(p.normalize).contains(normalized)) {
      return const VideoSubtitleCacheCleanupReport(
        removedEntries: 0,
        removedBytes: 0,
        skippedEntries: 1,
      );
    }
    final VideoSubtitleCacheSummary summary = await inspect();
    final VideoSubtitleCacheEntry? entry = _findEntry(
      summary.entries,
      normalized,
    );
    if (entry == null) {
      return const VideoSubtitleCacheCleanupReport(
        removedEntries: 0,
        removedBytes: 0,
        skippedEntries: 0,
      );
    }
    final int bytes = entry.bytes;
    await _deleteEntryFiles(entry);
    return VideoSubtitleCacheCleanupReport(
      removedEntries: 1,
      removedBytes: bytes,
      skippedEntries: 0,
    );
  }

  /// 删除所有非保护缓存；同时清理过期的原子写临时文件。
  Future<VideoSubtitleCacheCleanupReport> clearAll({
    Set<String> protectedMediaPaths = const <String>{},
  }) async {
    final VideoSubtitleCacheSummary summary = await inspect();
    int removedEntries = 0;
    int removedBytes = 0;
    int skippedEntries = 0;
    final Set<String> protected = protectedMediaPaths.map(p.normalize).toSet();
    for (final VideoSubtitleCacheEntry entry in summary.entries) {
      if (await _isProtectedEntry(entry, protected)) {
        skippedEntries++;
        continue;
      }
      await _deleteEntryFiles(entry);
      removedEntries++;
      removedBytes += entry.bytes;
    }
    await cleanupStaleTemporaryFiles(protectedMediaPaths: protectedMediaPaths);
    await _cleanupOrphanFiles(
      summary.entries,
      protectedMediaPaths: protectedMediaPaths,
    );
    return VideoSubtitleCacheCleanupReport(
      removedEntries: removedEntries,
      removedBytes: removedBytes,
      skippedEntries: skippedEntries,
    );
  }

  /// 只清理超过保留期限的临时文件；近期临时文件可能仍在原子写入中。
  Future<int> cleanupStaleTemporaryFiles({
    Duration maxAge = const Duration(days: 7),
    Set<String> protectedMediaPaths = const <String>{},
  }) async {
    final Directory directory = Directory(await directoryPath(create: false));
    if (!await directory.exists()) return 0;
    final DateTime cutoff = DateTime.now().subtract(maxAge);
    final Set<String> protected = protectedMediaPaths.map(p.normalize).toSet();
    int removed = 0;
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.tmp')) continue;
      final FileStat stat = await entity.stat();
      if (stat.modified.isAfter(cutoff)) continue;
      bool isProtected = false;
      for (final String mediaPath in protected) {
        final File jsonFile = await _jsonFile(
          mediaPath,
          createDirectory: false,
        );
        if (entity.path.startsWith('${jsonFile.path}.')) {
          isProtected = true;
          break;
        }
      }
      if (!isProtected) {
        await entity.delete();
        removed++;
      }
    }
    return removed;
  }

  /// 按最近访问时间保留缓存，保护当前播放/写入中的媒体不被驱逐。
  Future<VideoSubtitleCacheCleanupReport> trimToMaxBytes(
    int maxBytes, {
    Set<String> protectedMediaPaths = const <String>{},
  }) async {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final VideoSubtitleCacheSummary summary = await inspect();
    int remaining = summary.bytes;
    int removedEntries = 0;
    int removedBytes = 0;
    int skippedEntries = 0;
    final Set<String> protected = protectedMediaPaths.map(p.normalize).toSet();
    final List<VideoSubtitleCacheEntry> oldest =
        <VideoSubtitleCacheEntry>[...summary.entries]..sort(
          (VideoSubtitleCacheEntry left, VideoSubtitleCacheEntry right) =>
              left.lastAccessedAt.compareTo(right.lastAccessedAt),
        );
    for (final VideoSubtitleCacheEntry entry in oldest) {
      if (remaining <= maxBytes) break;
      if (await _isProtectedEntry(entry, protected)) {
        skippedEntries++;
        continue;
      }
      await _deleteEntryFiles(entry);
      remaining -= entry.bytes;
      removedEntries++;
      removedBytes += entry.bytes;
    }
    return VideoSubtitleCacheCleanupReport(
      removedEntries: removedEntries,
      removedBytes: removedBytes,
      skippedEntries: skippedEntries,
    );
  }

  Future<VideoSubtitleCacheEntry> _inspectFile(
    File jsonFile, {
    String? configurationScope,
  }) async {
    String mediaPath = jsonFile.path;
    String entryConfigurationScope = '';
    DateTime updatedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    bool isValid = false;
    bool isComplete = false;
    bool mediaMatches = false;
    try {
      final File metadataFile = await jsonFile.exists()
          ? jsonFile
          : File('${jsonFile.path}.checkpoint');
      final Object? decoded = jsonDecode(await metadataFile.readAsString());
      if (decoded is Map<String, dynamic>) {
        final Object? rawPath = decoded['media_path'];
        if (rawPath is String && rawPath.trim().isNotEmpty) {
          mediaPath = p.normalize(rawPath);
        }
        final Object? rawScope = decoded['configuration_scope'];
        if (rawScope is String) entryConfigurationScope = rawScope;
        final Object? rawUpdatedAt = decoded['updated_at'];
        if (rawUpdatedAt is String) {
          updatedAt = DateTime.tryParse(rawUpdatedAt) ?? updatedAt;
        }
        isComplete = decoded['complete'] != false;
        if (decoded['schema'] == kVideoSubtitleCacheSchema &&
            decoded['version'] == kVideoSubtitleCacheVersion &&
            decoded['result'] != null) {
          final TranscriptionResult result = TranscriptionResult.fromJson(
            decoded['result'],
          );
          ensureValidSubtitleTimeline(
            result.segments,
            duration: result.duration,
          );
          isValid = true;
        }
      }
    } on Object {
      // 保留损坏条目的文件信息，用户可以从缓存管理器中清除它。
    }
    final String srtPath = p.setExtension(jsonFile.path, '.srt');
    final String checkpointPath = '${jsonFile.path}.checkpoint';
    final File accessFile = await jsonFile.exists()
        ? jsonFile
        : File(checkpointPath);
    final DateTime lastAccessedAt = await accessFile.exists()
        ? (await accessFile.stat()).modified
        : updatedAt;
    final File media = File(mediaPath);
    final bool mediaExists = await media.exists();
    if (mediaExists) {
      try {
        final FileStat stat = await media.stat();
        final Object? decoded = await _readMetadataFile(jsonFile);
        if (decoded is Map<String, dynamic>) {
          mediaMatches =
              decoded['media_size'] == stat.size &&
              decoded['media_modified_ms'] ==
                  stat.modified.millisecondsSinceEpoch;
        }
      } on Object {
        mediaMatches = false;
      }
    }
    return VideoSubtitleCacheEntry(
      mediaPath: mediaPath,
      jsonPath: jsonFile.path,
      srtPath: srtPath,
      checkpointPath: checkpointPath,
      bytes:
          await _length(jsonFile) +
          await _length(File(srtPath)) +
          await _length(File(checkpointPath)),
      updatedAt: updatedAt,
      lastAccessedAt: lastAccessedAt,
      isValid: isValid,
      isComplete: isComplete,
      mediaExists: mediaExists,
      mediaMatches: mediaMatches,
      configurationMatches:
          configurationScope == null ||
          configurationScope == entryConfigurationScope,
    );
  }

  Future<Object?> _readMetadataFile(File jsonFile) async {
    final File metadataFile = await jsonFile.exists()
        ? jsonFile
        : File('${jsonFile.path}.checkpoint');
    return jsonDecode(await metadataFile.readAsString());
  }

  VideoSubtitleCacheEntry? _findEntry(
    List<VideoSubtitleCacheEntry> entries,
    String mediaPath,
  ) {
    for (final VideoSubtitleCacheEntry entry in entries) {
      if (p.normalize(entry.mediaPath) == mediaPath) return entry;
    }
    return null;
  }

  Future<bool> _isProtectedEntry(
    VideoSubtitleCacheEntry entry,
    Set<String> protectedMediaPaths,
  ) async {
    if (protectedMediaPaths.contains(p.normalize(entry.mediaPath))) {
      return true;
    }
    for (final String mediaPath in protectedMediaPaths) {
      final File jsonFile = await _jsonFile(mediaPath, createDirectory: false);
      if (jsonFile.path == entry.jsonPath) return true;
    }
    return false;
  }

  Future<void> _deleteEntryFiles(VideoSubtitleCacheEntry entry) async {
    for (final String path in <String>[
      entry.jsonPath,
      entry.srtPath,
      entry.checkpointPath,
    ]) {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  Future<int> _length(File file) async {
    if (!await file.exists()) return 0;
    return (await file.stat()).size;
  }

  Future<void> _cleanupOrphanFiles(
    List<VideoSubtitleCacheEntry> entries, {
    required Set<String> protectedMediaPaths,
  }) async {
    final Directory directory = Directory(await directoryPath(create: false));
    if (!await directory.exists()) return;
    final Set<String> known = <String>{
      for (final VideoSubtitleCacheEntry entry in entries) ...<String>[
        entry.jsonPath,
        entry.srtPath,
        entry.checkpointPath,
      ],
    };
    for (final String mediaPath in protectedMediaPaths) {
      final File jsonFile = await _jsonFile(mediaPath, createDirectory: false);
      known.addAll(<String>[
        jsonFile.path,
        p.setExtension(jsonFile.path, '.srt'),
        '${jsonFile.path}.checkpoint',
      ]);
    }
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File ||
          (!entity.path.endsWith('.srt') &&
              !entity.path.endsWith('.json.checkpoint'))) {
        continue;
      }
      if (!known.contains(entity.path)) await entity.delete();
    }
  }

  Future<File> _jsonFile(
    String mediaPath, {
    required bool createDirectory,
  }) async {
    final String directory = await directoryPath(create: createDirectory);
    final String normalized = p.normalize(mediaPath);
    final String digest = sha256
        .convert(utf8.encode(normalized))
        .toString()
        .substring(0, 12);
    final String rawName = p.basenameWithoutExtension(mediaPath);
    final String safeName = rawName
        .replaceAll(RegExp(r'[^A-Za-z0-9._\-\u4e00-\u9fff]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final String fileName =
        '${safeName.isEmpty ? 'video' : safeName}-$digest.json';
    return File(p.join(directory, fileName));
  }

  Future<File> _checkpointFile(
    String mediaPath, {
    required bool createDirectory,
  }) async {
    final File jsonFile = await _jsonFile(
      mediaPath,
      createDirectory: createDirectory,
    );
    return File('${jsonFile.path}.checkpoint');
  }

  Future<void> _atomicWrite(File target, String content) async {
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(content, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }
}
