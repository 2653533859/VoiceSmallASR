/// 字幕缓存管理对话框。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/video/video_subtitle_cache.dart';

class VideoSubtitleCacheDialog extends StatefulWidget {
  const VideoSubtitleCacheDialog({
    super.key,
    required this.cache,
    required this.initialSummary,
    required this.protectedMediaPaths,
    required this.cacheDirectory,
    required this.configurationScope,
  });

  final VideoSubtitleCache cache;
  final VideoSubtitleCacheSummary initialSummary;
  final Set<String> protectedMediaPaths;
  final String? cacheDirectory;
  final String configurationScope;

  @override
  State<VideoSubtitleCacheDialog> createState() =>
      _VideoSubtitleCacheDialogState();
}

class _VideoSubtitleCacheDialogState extends State<VideoSubtitleCacheDialog> {
  late VideoSubtitleCacheSummary _summary = widget.initialSummary;
  bool _busy = false;
  String? _cleanupResult;

  Future<void> _reload() async {
    final VideoSubtitleCacheSummary summary = await widget.cache.inspect(
      configurationScope: widget.configurationScope,
    );
    if (mounted) setState(() => _summary = summary);
  }

  Future<void> _delete(VideoSubtitleCacheEntry entry) async {
    setState(() => _busy = true);
    try {
      final VideoSubtitleCacheCleanupReport report = await widget.cache
          .deleteMedia(
            entry.mediaPath,
            protectedMediaPaths: widget.protectedMediaPaths,
          );
      await _reload();
      if (mounted) {
        setState(() => _cleanupResult = _formatCleanupReport(report));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除字幕缓存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll() async {
    setState(() => _busy = true);
    try {
      final VideoSubtitleCacheCleanupReport report = await widget.cache
          .clearAll(protectedMediaPaths: widget.protectedMediaPaths);
      await _reload();
      if (mounted) {
        setState(() => _cleanupResult = _formatCleanupReport(report));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清理字幕缓存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('字幕缓存管理'),
      content: SizedBox(
        width: 640,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '默认位置：${widget.cacheDirectory ?? '应用数据目录/video_subtitles'}\n'
              '共 ${_summary.entries.length} 项，${formatVideoCacheBytes(_summary.bytes)}；上限 ${formatVideoCacheBytes(kDefaultVideoSubtitleCacheMaxBytes)}',
            ),
            if (_cleanupResult != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(_cleanupResult!),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: _summary.entries.isEmpty
                  ? const Center(child: Text('暂无字幕缓存'))
                  : ListView.separated(
                      itemCount: _summary.entries.length,
                      separatorBuilder: (_, int index) =>
                          const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final VideoSubtitleCacheEntry entry =
                            _summary.entries[index];
                        final bool protected = widget.protectedMediaPaths
                            .map(p.normalize)
                            .contains(p.normalize(entry.mediaPath));
                        final String status = !entry.mediaExists
                            ? '原视频不存在'
                            : !entry.isValid
                            ? '缓存损坏'
                            : !entry.mediaMatches
                            ? '视频内容已变化'
                            : !entry.configurationMatches
                            ? '配置已变化'
                            : !entry.isComplete
                            ? '检查点'
                            : '可用';
                        return ListTile(
                          dense: true,
                          title: Text(
                            p.basename(entry.mediaPath),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '$status · ${formatVideoCacheBytes(entry.bytes)}\n'
                            '最后访问：${formatVideoCacheTime(entry.lastAccessedAt)}',
                          ),
                          trailing: IconButton(
                            tooltip: protected ? '当前使用中，暂不能删除' : '删除缓存',
                            onPressed: _busy || protected
                                ? null
                                : () => unawaited(_delete(entry)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => unawaited(_clearAll()),
          child: const Text('清理其他缓存'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

String _formatCleanupReport(VideoSubtitleCacheCleanupReport report) =>
    '清理结果：已移除 ${report.removedEntries} 项 '
    '(${formatVideoCacheBytes(report.removedBytes)})，保护 ${report.skippedEntries} 项';

String formatVideoCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatVideoCacheTime(DateTime value) {
  final DateTime local = value.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
