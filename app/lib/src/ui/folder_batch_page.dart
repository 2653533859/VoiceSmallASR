/// 文件夹队列界面，整条队列顺序执行。
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/ui/folder_batch_controller.dart';

class FolderBatchPage extends StatefulWidget {
  const FolderBatchPage({
    super.key,
    required this.controller,
    required this.pickDirectory,
    this.pickOutputDirectory,
  });
  final FolderBatchController controller;
  final Future<String?> Function() pickDirectory;
  final Future<String?> Function()? pickOutputDirectory;
  @override
  State<FolderBatchPage> createState() => _FolderBatchPageState();
}

class _FolderBatchPageState extends State<FolderBatchPage> {
  FolderItemFilter _filter = FolderItemFilter.all;
  String? _error;
  Future<void> _select() async {
    try {
      final path = await widget.pickDirectory();
      if (path != null && mounted) {
        await widget.controller.selectDirectory(path);
      }
      if (mounted) {
        setState(() {
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
        });
      }
    }
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
    });
    try {
      await widget.controller.start();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
        });
      }
    }
  }

  Future<void> _selectOutputDirectory() async {
    try {
      final path = await (widget.pickOutputDirectory ?? widget.pickDirectory)();
      if (path != null && mounted) {
        widget.controller.updateOptions(outputDirectory: path);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final locked = c.running || c.loading;
      final visibleItems = c.items.indexed
          .where((entry) {
            final status = entry.$2.status;
            return switch (_filter) {
              FolderItemFilter.all => true,
              FolderItemFilter.pending =>
                status == FolderItemStatus.queued ||
                    status == FolderItemStatus.transcribing ||
                    status == FolderItemStatus.translating,
              FolderItemFilter.failed => status == FolderItemStatus.failed,
              FolderItemFilter.completed =>
                status == FolderItemStatus.completed,
              FolderItemFilter.skipped => status == FolderItemStatus.skipped,
            };
          })
          .toList(growable: false);
      return Scaffold(
        appBar: AppBar(title: const Text('文件夹批量处理')),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '仅处理所选文件夹当前层，按自然文件名顺序（1、2、10）逐个完成。已有同名 SRT/VTT/ASS/SSA 字幕直接跳过，包括语言后缀字幕。',
                  ),
                  const Text('任务会自动保存；返回主界面后仍会继续，可从任务中心查看或暂停。不会覆盖已有字幕。'),
                  if (c.directory != null) Text(c.directory!),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        key: const Key('folderPick'),
                        onPressed: locked ? null : _select,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('选择文件夹'),
                      ),
                      FilledButton(
                        key: const Key('folderStart'),
                        onPressed: locked || !c.hasPending ? null : _start,
                        child: const Text('开始 / 继续'),
                      ),
                      TextButton(
                        onPressed: c.running ? c.stopAfterCurrent : null,
                        child: const Text('完成当前文件后暂停'),
                      ),
                      TextButton.icon(
                        key: const Key('folderCancelNow'),
                        onPressed: c.running ? c.cancelNow : null,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('立即暂停'),
                      ),
                      FilterChip(
                        label: const Text('转写后自动翻译'),
                        selected: c.translate,
                        onSelected: locked
                            ? null
                            : (value) => c.updateOptions(translate: value),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<String>(
                        key: const Key('folderFormat'),
                        value: c.format,
                        onChanged: locked
                            ? null
                            : (value) {
                                if (value != null) {
                                  c.updateOptions(format: value);
                                }
                              },
                        items: const ['srt', 'vtt', 'json', 'txt']
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value.toUpperCase()),
                              ),
                            )
                            .toList(),
                      ),
                      DropdownButton<String>(
                        key: const Key('folderLanguage'),
                        value: c.language,
                        onChanged: locked
                            ? null
                            : (value) {
                                if (value != null) {
                                  c.updateOptions(language: value);
                                }
                              },
                        items: kLanguages
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(
                                  '整批语言：${kLanguageLabels[value] ?? value}',
                                ),
                              ),
                            )
                            .toList(),
                      ),
                      OutlinedButton.icon(
                        key: const Key('folderOutputDirectory'),
                        onPressed: locked ? null : _selectOutputDirectory,
                        icon: const Icon(Icons.drive_folder_upload_outlined),
                        label: const Text('选择输出文件夹'),
                      ),
                      if (c.outputDirectory != null)
                        TextButton(
                          onPressed: locked
                              ? null
                              : () =>
                                    c.updateOptions(clearOutputDirectory: true),
                          child: const Text('改回媒体旁'),
                        ),
                      DropdownButton<FolderConflictPolicy>(
                        key: const Key('folderConflictPolicy'),
                        value: c.conflictPolicy,
                        onChanged: locked
                            ? null
                            : (value) {
                                if (value != null) {
                                  c.updateOptions(conflictPolicy: value);
                                }
                              },
                        items: const [
                          DropdownMenuItem(
                            value: FolderConflictPolicy.skip,
                            child: Text('目标重名时跳过'),
                          ),
                          DropdownMenuItem(
                            value: FolderConflictPolicy.numbered,
                            child: Text('目标重名时自动编号'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Text(
                    c.outputDirectory == null
                        ? '输出：媒体文件旁 · ${c.format.toUpperCase()} · ${c.translate ? '双语' : '原文'}'
                        : '输出：${c.outputDirectory} · ${c.format.toUpperCase()} · ${c.translate ? '双语' : '原文'}',
                  ),
                  Text(
                    '共 ${c.items.length} 个 · 完成 ${c.items.where((i) => i.status == FolderItemStatus.completed).length} · 跳过 ${c.items.where((i) => i.status == FolderItemStatus.skipped).length} · 失败 ${c.items.where((i) => i.status == FolderItemStatus.failed).length}',
                  ),
                  DropdownButton<FolderItemFilter>(
                    key: const Key('folderStatusFilter'),
                    value: _filter,
                    onChanged: (value) {
                      if (value != null) setState(() => _filter = value);
                    },
                    items: const [
                      DropdownMenuItem(
                        value: FolderItemFilter.all,
                        child: Text('显示全部'),
                      ),
                      DropdownMenuItem(
                        value: FolderItemFilter.pending,
                        child: Text('仅等待中'),
                      ),
                      DropdownMenuItem(
                        value: FolderItemFilter.failed,
                        child: Text('仅失败'),
                      ),
                      DropdownMenuItem(
                        value: FolderItemFilter.completed,
                        child: Text('仅完成'),
                      ),
                      DropdownMenuItem(
                        value: FolderItemFilter.skipped,
                        child: Text('仅跳过'),
                      ),
                    ],
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            if (locked) const LinearProgressIndicator(),
            Expanded(
              child: c.items.isEmpty
                  ? const Center(child: Text('选择文件夹后预览队列，再点击开始'))
                  : visibleItems.isEmpty
                  ? const Center(child: Text('当前筛选条件下没有任务'))
                  : ListView.builder(
                      itemCount: visibleItems.length,
                      itemBuilder: (context, index) {
                        final entry = visibleItems[index];
                        final originalIndex = entry.$1;
                        final item = entry.$2;
                        final status = switch (item.status) {
                          FolderItemStatus.queued => '等待中',
                          FolderItemStatus.skipped => '已跳过',
                          FolderItemStatus.transcribing => '转写中',
                          FolderItemStatus.translating => '翻译中',
                          FolderItemStatus.completed => '已完成',
                          FolderItemStatus.failed => '失败（再次开始可重试）',
                        };
                        return ListTile(
                          title: Text(
                            '${originalIndex + 1}. ${p.basename(item.path)}',
                          ),
                          subtitle: Text(
                            '$status · 语言：${item.languageOverride == null ? '跟随整批' : kLanguageLabels[item.languageOverride] ?? item.languageOverride}'
                            '${item.detail == null ? '' : '\n${item.detail}'}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (item.status == FolderItemStatus.failed)
                                IconButton(
                                  tooltip: '重新排队',
                                  onPressed: locked
                                      ? null
                                      : () => c.retryItem(originalIndex),
                                  icon: const Icon(Icons.refresh),
                                ),
                              PopupMenuButton<String>(
                                tooltip: '设置此文件的识别语言',
                                enabled:
                                    !locked &&
                                    (item.status == FolderItemStatus.queued ||
                                        item.status == FolderItemStatus.failed),
                                onSelected: (value) => c.setItemLanguage(
                                  originalIndex,
                                  value.isEmpty ? null : value,
                                ),
                                itemBuilder: (context) =>
                                    <PopupMenuEntry<String>>[
                                      const PopupMenuItem(
                                        value: '',
                                        child: Text('跟随整批设置'),
                                      ),
                                      for (final value in kLanguages)
                                        PopupMenuItem(
                                          value: value,
                                          child: Text(
                                            kLanguageLabels[value] ?? value,
                                          ),
                                        ),
                                    ],
                                icon: const Icon(Icons.language),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}

enum FolderItemFilter { all, pending, failed, completed, skipped }
