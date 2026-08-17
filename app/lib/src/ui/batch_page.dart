/// 批量文件处理页面：选择队列、顺序转写/翻译、暂停、取消和失败重试。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';

class BatchPage extends StatefulWidget {
  const BatchPage({
    super.key,
    required this.controller,
    required this.pickFiles,
    this.onTranslate,
  });

  final BatchTranscriptionController controller;
  final PickBatchFiles pickFiles;
  final Future<void> Function()? onTranslate;

  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> {
  bool _translationStarting = false;

  Future<void> _pickFiles() async {
    try {
      final List<String> paths = await widget.pickFiles();
      if (paths.isNotEmpty) widget.controller.enqueue(paths);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('选择批量文件失败：$error')));
    }
  }

  Future<void> _start() async {
    try {
      await widget.controller.start();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('启动批量处理失败：$error')));
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.controller.cancel();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('批量处理已取消')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('取消批量处理失败：$error')));
    }
  }

  Future<void> _translate() async {
    final Future<void> Function()? translate = widget.onTranslate;
    if (translate == null || _translationStarting) return;
    setState(() => _translationStarting = true);
    try {
      await translate();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('批量翻译失败：$error')));
    } finally {
      if (mounted) setState(() => _translationStarting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('批量处理')),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (BuildContext context, Widget? _) {
          final BatchTranscriptionController batch = widget.controller;
          final bool canStart =
              !batch.running && (batch.hasQueuedItems || batch.paused);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    FilledButton.icon(
                      key: const Key('batchPickFiles'),
                      onPressed: batch.running ? null : _pickFiles,
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('选择多个文件'),
                    ),
                    FilledButton.icon(
                      key: const Key('batchStart'),
                      onPressed: canStart ? _start : null,
                      icon: Icon(batch.paused ? Icons.play_arrow : Icons.start),
                      label: Text(batch.paused ? '继续' : '开始'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('batchPause'),
                      onPressed: batch.running && !batch.translating
                          ? batch.pause
                          : null,
                      icon: const Icon(Icons.pause),
                      label: const Text('暂停'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('batchCancel'),
                      onPressed: batch.running || batch.paused ? _cancel : null,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('取消'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('batchTranslate'),
                      onPressed:
                          batch.running ||
                              !batch.hasTranslatableItems ||
                              widget.onTranslate == null ||
                              _translationStarting
                          ? null
                          : _translate,
                      icon: const Icon(Icons.translate),
                      label: const Text('批量翻译'),
                    ),
                    Text('已完成 ${batch.completedCount}/${batch.items.length}'),
                    Text('已翻译 ${batch.translatedCount}/${batch.items.length}'),
                  ],
                ),
              ),
              if (batch.running) const LinearProgressIndicator(),
              Expanded(
                child: batch.items.isEmpty
                    ? const Center(child: Text('选择多个音频或视频文件开始'))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        itemCount: batch.items.length,
                        itemBuilder: (BuildContext context, int index) {
                          return _BatchItemTile(
                            key: Key('batchItem$index'),
                            item: batch.items[index],
                            onRetry:
                                batch.items[index].status ==
                                        BatchItemStatus.failed &&
                                    !batch.running
                                ? () => unawaited(_retry(index))
                                : batch.items[index].status ==
                                          BatchItemStatus.translationFailed &&
                                      !batch.running &&
                                      widget.onTranslate != null &&
                                      !_translationStarting
                                ? () => unawaited(_retryTranslation(index))
                                : null,
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _retry(int index) async {
    try {
      await widget.controller.retry(index);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重试失败：$error')));
    }
  }

  Future<void> _retryTranslation(int index) async {
    try {
      widget.controller.retryTranslation(index);
      await _translate();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重试翻译失败：$error')));
    }
  }
}

class _BatchItemTile extends StatelessWidget {
  const _BatchItemTile({super.key, required this.item, this.onRetry});

  final BatchItem item;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final double? progress = item.progress;
    final String detail = item.errorText == null
        ? '${item.statusLabel}${item.attempts > 0 ? ' · 第 ${item.attempts} 次' : ''}'
        : '${item.statusLabel}：${item.errorText}';
    return Card(
      child: ListTile(
        title: Text(p.basename(item.path), overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(detail),
            if (progress != null &&
                (item.status == BatchItemStatus.processing ||
                    item.status == BatchItemStatus.translating))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(value: progress),
              ),
          ],
        ),
        trailing: onRetry == null
            ? null
            : IconButton(
                key: Key('batchRetry${item.path}'),
                tooltip: '重试',
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
              ),
      ),
    );
  }
}
