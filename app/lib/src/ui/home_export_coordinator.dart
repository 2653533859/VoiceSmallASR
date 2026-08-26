/// 首页批量字幕导出的业务协调器。
library;

import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';

/// 将一个导出文件交给界面层保存；返回 null 表示用户取消保存。
typedef HomeExportFile = Future<String?> Function(
  String fileName,
  String content, {
  required String dialogTitle,
});

/// 一次批量导出的结果汇总。
class HomeBatchExportSummary {
  const HomeBatchExportSummary({
    required this.totalCount,
    required this.exportedCount,
    required this.failedCount,
    required this.cancelled,
    this.lastError,
  });

  final int totalCount;
  final int exportedCount;
  final int failedCount;
  final bool cancelled;
  final Object? lastError;
}

/// 负责筛选可导出条目、生成安全文件名并顺序保存字幕。
class HomeExportCoordinator {
  Future<HomeBatchExportSummary> exportBatch({
    required Iterable<BatchItem> items,
    required String format,
    required HomeExportFile saveFile,
  }) async {
    final String normalizedFormat = format.trim().toLowerCase();
    if (!kSubtitleFormats.contains(normalizedFormat)) {
      throw ArgumentError.value(format, 'format', '不支持的批量导出格式');
    }
    final List<BatchItem> exportable = items
        .where(
          (BatchItem item) =>
              (item.status == BatchItemStatus.completed ||
                  item.status == BatchItemStatus.translated) &&
              item.result != null,
        )
        .toList(growable: false);
    if (exportable.isEmpty) {
      return const HomeBatchExportSummary(
        totalCount: 0,
        exportedCount: 0,
        failedCount: 0,
        cancelled: false,
      );
    }

    final Set<String> usedBaseNames = <String>{};
    int exported = 0;
    int failed = 0;
    bool cancelled = false;
    Object? lastError;
    for (int index = 0; index < exportable.length; index++) {
      final BatchItem item = exportable[index];
      final TranscriptionResult result = item.result!;
      final String baseName = _batchExportBaseName(
        item.path,
        usedBaseNames,
        fallbackIndex: index + 1,
      );
      final String fileName = '$baseName.$normalizedFormat';
      try {
        final String? saved = await saveFile(
          fileName,
          renderSubtitles(result, normalizedFormat),
          dialogTitle: '批量导出（${index + 1}/${exportable.length}）',
        );
        if (saved == null) {
          cancelled = true;
          break;
        }
        exported++;
      } on Object catch (error) {
        failed++;
        lastError = error;
      }
    }
    return HomeBatchExportSummary(
      totalCount: exportable.length,
      exportedCount: exported,
      failedCount: failed,
      cancelled: cancelled,
      lastError: lastError,
    );
  }

  String _batchExportBaseName(
    String path,
    Set<String> used, {
    required int fallbackIndex,
  }) {
    String base = p.basenameWithoutExtension(path).trim();
    base = base
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[ .]+$'), '')
        .trim();
    if (base.isEmpty) base = 'subtitle-$fallbackIndex';
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
      caseSensitive: false,
    ).hasMatch(base)) {
      base = '_$base';
    }
    String candidate = base;
    int suffix = 2;
    while (!used.add(candidate.toLowerCase())) {
      candidate = '$base-$suffix';
      suffix++;
    }
    return candidate;
  }
}
