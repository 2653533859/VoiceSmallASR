/// 批量翻译结果的本地缓存。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

const String kBatchTranslationCacheSchema =
    'voicesmallasr.batch_translation_cache';
const int kBatchTranslationCacheVersion = 1;
const int kMaxBatchTranslationCacheEntries = 64;

/// 只缓存翻译后的字幕结果，不保存 API Key 或 provider 的认证信息。
///
/// 缓存键同时包含媒体路径、未带译文的识别结果、目标语言和 provider 配置，
/// 因此同一文件重新识别、切换目标语言或切换服务商后不会误用旧译文。
class BatchTranslationCache {
  const BatchTranslationCache({this.rootDirectory});

  final Directory? rootDirectory;

  /// 读取与当前识别结果完全匹配的译文；缓存损坏或格式过期时按未命中处理。
  Future<TranscriptionResult?> read({
    required String mediaPath,
    required TranscriptionResult source,
    required String targetLanguage,
    required String providerScope,
  }) async {
    final Map<String, dynamic> document = await _load();
    final Map<String, dynamic> entries = _entries(document);
    final dynamic raw =
        entries[_cacheKey(
          mediaPath: mediaPath,
          result: source,
          targetLanguage: targetLanguage,
          providerScope: providerScope,
        )];
    if (raw is! Map<String, dynamic> || raw['result'] == null) return null;
    try {
      final TranscriptionResult translated = TranscriptionResult.fromJson(
        raw['result'],
      );
      ensureValidSubtitleTimeline(
        translated.segments,
        duration: translated.duration,
      );
      if (!_sameSource(source, translated) ||
          !_hasTranslations(source, translated)) {
        return null;
      }
      return translated;
    } on Object {
      return null;
    }
  }

  /// 原子写入一个成功的翻译结果，并限制缓存条目数量，避免长期占满磁盘。
  Future<void> write({
    required String mediaPath,
    required TranscriptionResult translated,
    required String targetLanguage,
    required String providerScope,
  }) async {
    ensureValidSubtitleTimeline(
      translated.segments,
      duration: translated.duration,
    );
    final File file = await _file(createDirectory: true);
    final Map<String, dynamic> document = await _load();
    final Map<String, dynamic> entries = _entries(document);
    final String key = _cacheKey(
      mediaPath: mediaPath,
      result: translated,
      targetLanguage: targetLanguage,
      providerScope: providerScope,
    );
    entries[key] = <String, dynamic>{
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'media_path': mediaPath.trim(),
      'target_language': targetLanguage.trim(),
      'result': translated.toJson(),
    };
    _trim(entries);
    final String content = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{
          'schema': kBatchTranslationCacheSchema,
          'version': kBatchTranslationCacheVersion,
          'entries': entries,
        });
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString('$content\n', flush: true);
    await temporary.rename(file.path);
  }

  Future<File> _file({required bool createDirectory}) async {
    final Directory support =
        rootDirectory ?? await getApplicationSupportDirectory();
    final Directory directory = Directory(
      p.join(support.path, 'batch_translation_cache'),
    );
    if (createDirectory) await directory.create(recursive: true);
    return File(p.join(directory.path, 'translations.json'));
  }

  Future<Map<String, dynamic>> _load() async {
    final File file = await _file(createDirectory: false);
    if (!file.existsSync()) return <String, dynamic>{};
    try {
      final dynamic decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != kBatchTranslationCacheSchema ||
          decoded['version'] != kBatchTranslationCacheVersion) {
        return <String, dynamic>{};
      }
      return decoded;
    } on Object {
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _entries(Map<String, dynamic> document) {
    final dynamic raw = document['entries'];
    if (raw is! Map<String, dynamic>) return <String, dynamic>{};
    return Map<String, dynamic>.of(raw);
  }

  void _trim(Map<String, dynamic> entries) {
    if (entries.length <= kMaxBatchTranslationCacheEntries) return;
    final List<String> keys = entries.keys.toList()
      ..sort((String a, String b) {
        final String left = _updatedAt(entries[a]);
        final String right = _updatedAt(entries[b]);
        return left.compareTo(right);
      });
    final int removeCount = entries.length - kMaxBatchTranslationCacheEntries;
    for (final String key in keys.take(removeCount)) {
      entries.remove(key);
    }
  }

  String _updatedAt(dynamic value) {
    if (value is Map<String, dynamic> && value['updated_at'] is String) {
      return value['updated_at'] as String;
    }
    return '';
  }
}

String _cacheKey({
  required String mediaPath,
  required TranscriptionResult result,
  required String targetLanguage,
  required String providerScope,
}) {
  final Map<String, dynamic> identity = <String, dynamic>{
    'media_path': mediaPath.trim(),
    'target_language': targetLanguage.trim(),
    'provider_scope': providerScope.trim(),
    'source': _sourceJson(result),
  };
  return sha256.convert(utf8.encode(jsonEncode(identity))).toString();
}

Map<String, dynamic> _sourceJson(TranscriptionResult result) {
  final Map<String, dynamic> json = Map<String, dynamic>.of(result.toJson())
    ..remove('text');
  final List<dynamic> rawSegments = json['segments'] as List<dynamic>;
  json['segments'] = rawSegments
      .map((dynamic raw) {
        final Map<String, dynamic> segment = Map<String, dynamic>.of(
          raw as Map<String, dynamic>,
        );
        segment.remove('translation');
        return segment;
      })
      .toList(growable: false);
  return json;
}

bool _sameSource(TranscriptionResult source, TranscriptionResult translated) {
  final Map<String, dynamic> leftJson = _sourceJson(source);
  final Map<String, dynamic> rightJson = _sourceJson(translated);
  final List<dynamic> left = leftJson['segments'] as List<dynamic>;
  final List<dynamic> right = rightJson['segments'] as List<dynamic>;
  return leftJson['language'] == rightJson['language'] &&
      leftJson['duration'] == rightJson['duration'] &&
      jsonEncode(left) == jsonEncode(right);
}

bool _hasTranslations(
  TranscriptionResult source,
  TranscriptionResult translated,
) {
  for (int index = 0; index < source.segments.length; index++) {
    if (source.segments[index].text.trim().isNotEmpty &&
        translated.segments[index].translation?.trim().isEmpty != false) {
      return false;
    }
  }
  return true;
}
