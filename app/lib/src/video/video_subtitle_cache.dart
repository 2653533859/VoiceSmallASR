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
