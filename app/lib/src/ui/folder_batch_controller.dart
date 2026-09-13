/// 文件夹顺序处理：扫描、跳过同名字幕、逐文件转写/翻译并落盘。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/audio/media_file_order.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/ui/folder_batch_store.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';

typedef FolderTranslation = ({
  TranslationProvider provider,
  String targetLanguage,
});

typedef FolderTranscribeWithLanguage = Future<TranscriptionResult?> Function(
  String path,
  String language,
);

enum FolderItemStatus {
  queued,
  skipped,
  transcribing,
  translating,
  completed,
  failed,
}

enum FolderConflictPolicy { skip, numbered }

class FolderItem {
  FolderItem(
    this.path, {
    this.status = FolderItemStatus.queued,
    this.languageOverride,
  });
  final String path;
  FolderItemStatus status;
  String? detail;
  String? languageOverride;
}

Future<String?> existingSubtitle(String mediaPath) async {
  final stem = p.basenameWithoutExtension(mediaPath).toLowerCase();
  await for (final entry in Directory(
    p.dirname(mediaPath),
  ).list(followLinks: false)) {
    if (entry is! File) continue;
    final ext = p.extension(entry.path).toLowerCase();
    if (!const {'.srt', '.vtt', '.ass', '.ssa'}.contains(ext)) continue;
    final name = p.basenameWithoutExtension(entry.path).toLowerCase();
    final suffix = name.startsWith('$stem.')
        ? name.substring(stem.length + 1)
        : '';
    final languageSuffix =
        RegExp(r'^[a-z]{2,3}([_-][a-z]{2,4})?$').hasMatch(suffix) ||
        const {'translated', 'bilingual', '双语', '中文', '日文'}.contains(suffix);
    if (name == stem || languageSuffix) return entry.path;
  }
  return null;
}

class FolderBatchController extends ChangeNotifier {
  FolderBatchController({
    this.transcribe,
    this.transcribeWithLanguage,
    this.cancelCurrent,
    required this.prepareTranslation,
    this.store,
    String initialLanguage = 'auto',
  }) : assert(transcribe != null || transcribeWithLanguage != null),
       language = kLanguages.contains(initialLanguage)
           ? initialLanguage
           : 'auto';
  final Future<TranscriptionResult?> Function(String path)? transcribe;
  final FolderTranscribeWithLanguage? transcribeWithLanguage;
  final Future<void> Function()? cancelCurrent;
  final Future<FolderTranslation?> Function() prepareTranslation;
  final FolderBatchStore? store;
  final List<FolderItem> _items = [];
  List<FolderItem> get items => List.unmodifiable(_items);
  String? directory;
  bool running = false;
  bool loading = false;
  bool paused = false;
  bool translate = true;
  String format = 'srt';
  String language;
  String? outputDirectory;
  FolderConflictPolicy conflictPolicy = FolderConflictPolicy.skip;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  Timer? _saveTimer;
  Future<void> _saveChain = Future<void>.value();
  bool get hasPending => _items.any(
    (i) =>
        i.status == FolderItemStatus.queued ||
        i.status == FolderItemStatus.failed,
  );

  void _notify() {
    if (!_disposed) {
      notifyListeners();
      _scheduleSave();
    }
  }

  void updateOptions({
    bool? translate,
    String? format,
    String? language,
    String? outputDirectory,
    bool clearOutputDirectory = false,
    FolderConflictPolicy? conflictPolicy,
  }) {
    if (running || loading) return;
    if (translate != null) this.translate = translate;
    if (format != null && kSubtitleFormats.contains(format)) {
      this.format = format;
    }
    if (language != null && kLanguages.contains(language)) {
      this.language = language;
    }
    if (clearOutputDirectory) {
      this.outputDirectory = null;
    } else if (outputDirectory != null) {
      this.outputDirectory = outputDirectory;
    }
    if (conflictPolicy != null) this.conflictPolicy = conflictPolicy;
    _notify();
  }

  Future<bool> restore() async {
    final snapshot = await store?.load();
    if (snapshot == null || snapshot.items.isEmpty) return false;
    final restored = <FolderItem>[];
    for (final saved in snapshot.items) {
      final status = FolderItemStatus.values
          .where((value) => value.name == saved.status)
          .firstOrNull;
      if (status == null) continue;
      final normalized = switch (status) {
        FolderItemStatus.transcribing ||
        FolderItemStatus.translating => FolderItemStatus.queued,
        _ => status,
      };
      restored.add(
        FolderItem(
          saved.path,
          status: normalized,
          languageOverride:
              saved.language != null && kLanguages.contains(saved.language)
              ? saved.language
              : null,
        )..detail = normalized == status ? saved.detail : '上次处理意外中断，可继续',
      );
    }
    if (restored.isEmpty) return false;
    _items
      ..clear()
      ..addAll(restored);
    directory = snapshot.directory;
    translate = snapshot.translate;
    language = kLanguages.contains(snapshot.language)
        ? snapshot.language
        : 'auto';
    format = kSubtitleFormats.contains(snapshot.format)
        ? snapshot.format
        : 'srt';
    outputDirectory = snapshot.outputDirectory;
    conflictPolicy =
        FolderConflictPolicy.values
            .where((value) => value.name == snapshot.conflictPolicy)
            .firstOrNull ??
        FolderConflictPolicy.skip;
    paused = true;
    _notify();
    return true;
  }

  Future<void> selectDirectory(String path) async {
    if (running || loading) throw StateError('请等待当前操作完成');
    loading = true;
    _notify();
    try {
      final paths = <String>[];
      await for (final entry in Directory(path).list(followLinks: false)) {
        if (entry is File &&
            kSupportedAudioExtensions.contains(
              p.extension(entry.path).replaceFirst('.', '').toLowerCase(),
            )) {
          paths.add(entry.path);
        }
      }
      paths.sort(compareMediaNames);
      final next = <FolderItem>[];
      for (final media in paths) {
        final subtitle = await existingSubtitle(media);
        final item = FolderItem(
          media,
          status: subtitle == null
              ? FolderItemStatus.queued
              : FolderItemStatus.skipped,
        );
        item.detail = subtitle == null ? null : '已有字幕：${p.basename(subtitle)}';
        next.add(item);
      }
      if (_disposed) return;
      _items
        ..clear()
        ..addAll(next);
      directory = path;
      paused = false;
    } finally {
      loading = false;
      _notify();
    }
  }

  void stopAfterCurrent() {
    _pauseRequested = true;
    paused = true;
    _notify();
  }

  Future<void> cancelNow() async {
    if (!running || _cancelRequested) return;
    _pauseRequested = true;
    _cancelRequested = true;
    paused = true;
    _notify();
    await cancelCurrent?.call();
  }

  void retryItem(int index) {
    if (running || loading || index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item.status != FolderItemStatus.failed) return;
    item
      ..status = FolderItemStatus.queued
      ..detail = null;
    _notify();
  }

  void setItemLanguage(int index, String? language) {
    if (running || loading || index < 0 || index >= _items.length) return;
    if (language != null && !kLanguages.contains(language)) return;
    _items[index].languageOverride = language;
    _notify();
  }

  Future<void> start({bool? translate}) async {
    if (running || loading || !hasPending) return;
    if (translate != null) this.translate = translate;
    running = true;
    paused = false;
    _pauseRequested = false;
    _cancelRequested = false;
    _notify();
    FolderTranslation? translation;
    try {
      for (final item in _items) {
        if (_pauseRequested || _disposed) break;
        if (item.status != FolderItemStatus.queued &&
            item.status != FolderItemStatus.failed) {
          continue;
        }
        if (!File(item.path).existsSync()) {
          item.status = FolderItemStatus.failed;
          item.detail = '媒体文件不存在';
          _notify();
          continue;
        }
        // 排队期间可能由其他工具生成字幕，处理前再次检查。
        final existing = await existingSubtitle(item.path);
        if (existing != null) {
          item.status = FolderItemStatus.skipped;
          item.detail = '已有字幕：${p.basename(existing)}';
          _notify();
          continue;
        }
        final baseTarget = File(_baseTargetPath(item.path));
        if (conflictPolicy == FolderConflictPolicy.skip &&
            baseTarget.existsSync()) {
          item.status = FolderItemStatus.skipped;
          item.detail = '输出文件已存在：${p.basename(baseTarget.path)}';
          _notify();
          continue;
        }
        if (this.translate && translation == null) {
          translation = await prepareTranslation();
          if (translation == null || _pauseRequested || _disposed) break;
        }
        if (_pauseRequested || _disposed) break;
        try {
          item.status = FolderItemStatus.transcribing;
          item.detail = null;
          _notify();
          final effectiveLanguage = item.languageOverride ?? language;
          var result = await (transcribeWithLanguage != null
              ? transcribeWithLanguage!(item.path, effectiveLanguage)
              : transcribe!(item.path));
          if (_cancelRequested) {
            item.status = FolderItemStatus.queued;
            item.detail = '已暂停，可继续';
            _notify();
            break;
          }
          if (_disposed) break;
          if (result == null || result.segments.isEmpty) {
            throw StateError('未识别到字幕，未生成文件');
          }
          if (this.translate) {
            item.status = FolderItemStatus.translating;
            _notify();
            result = await translateResult(
              result,
              translation!.provider,
              to: translation.targetLanguage,
              isCancelled: () => _disposed || _cancelRequested,
            );
          }
          if (_cancelRequested) {
            item.status = FolderItemStatus.queued;
            item.detail = '已暂停，可继续';
            _notify();
            break;
          }
          if (_disposed) break;
          final existing = await existingSubtitle(item.path);
          if (existing != null) {
            item.status = FolderItemStatus.skipped;
            item.detail = '处理期间出现字幕，保留已有文件';
          } else {
            final target = await _targetFile(item.path);
            if (target == null) {
              item.status = FolderItemStatus.skipped;
              item.detail = '输出文件已存在，未覆盖';
              _notify();
              continue;
            }
            // 独占创建，不覆盖已有字幕；写入失败时清理本次创建的文件。
            await target.create(exclusive: true);
            try {
              await target.writeAsString(
                renderSubtitles(result, format, bilingual: this.translate),
                flush: true,
              );
            } catch (_) {
              await target.delete();
              rethrow;
            }
            item.status = FolderItemStatus.completed;
            final warning = _languageWarning(result, effectiveLanguage);
            final saved = '已保存：${p.basename(target.path)}';
            item.detail = warning == null ? saved : '$saved\n$warning';
          }
        } catch (error) {
          if (_cancelRequested) {
            item.status = FolderItemStatus.queued;
            item.detail = '已暂停，可继续';
          } else {
            item.status = FolderItemStatus.failed;
            item.detail = '$error';
          }
        }
        _notify();
      }
    } finally {
      final provider = translation?.provider;
      try {
        if (provider is ClosableTranslationProvider) provider.close();
      } finally {
        running = false;
        if (!hasPending) paused = false;
        _notify();
      }
    }
  }

  Future<File?> _targetFile(String mediaPath) async {
    final directory = outputDirectory ?? p.dirname(mediaPath);
    await Directory(directory).create(recursive: true);
    final stem = p.basenameWithoutExtension(mediaPath);
    var target = File(_baseTargetPath(mediaPath));
    if (!target.existsSync()) return target;
    if (conflictPolicy == FolderConflictPolicy.skip) return null;
    var suffix = 2;
    while (target.existsSync()) {
      target = File(p.join(directory, '$stem ($suffix).$format'));
      suffix++;
    }
    return target;
  }

  String _baseTargetPath(String mediaPath) {
    final directory = outputDirectory ?? p.dirname(mediaPath);
    final stem = p.basenameWithoutExtension(mediaPath);
    return p.join(directory, '$stem.$format');
  }

  String? _languageWarning(TranscriptionResult result, String expected) {
    if (expected == 'auto') return null;
    final detected = result.segments
        .map((segment) => segment.language.trim().toLowerCase())
        .where((value) => value.isNotEmpty && value != 'auto')
        .toSet();
    if (detected.isEmpty || detected.every((value) => value == expected)) {
      return null;
    }
    return '语言提示：指定 $expected，检测到 ${detected.join('/')}，建议检查原文';
  }

  void _scheduleSave() {
    if (store == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _persist);
  }

  void _persist() {
    final targetStore = store;
    if (targetStore == null) return;
    final hasRecoverable = hasPending || running || paused;
    final snapshot = FolderBatchSnapshot(
      directory: directory ?? '',
      items: _items
          .map(
            (item) => FolderBatchSavedItem(
              path: item.path,
              status: item.status.name,
              detail: item.detail,
              language: item.languageOverride,
            ),
          )
          .toList(growable: false),
      translate: translate,
      format: format,
      conflictPolicy: conflictPolicy.name,
      language: language,
      outputDirectory: outputDirectory,
      paused: paused,
    );
    _saveChain = _saveChain.then(
      (_) => hasRecoverable && snapshot.items.isNotEmpty
          ? targetStore.save(snapshot)
          : targetStore.clear(),
    );
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _persist();
    await _saveChain;
  }

  @override
  void dispose() {
    _disposed = true;
    _pauseRequested = true;
    _saveTimer?.cancel();
    super.dispose();
  }
}
