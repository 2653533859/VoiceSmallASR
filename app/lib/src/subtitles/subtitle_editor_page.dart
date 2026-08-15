/// 字幕校对页面：编辑文本/时间、合并/拆分，并可联动播放器定位。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_controller.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

typedef SaveSubtitleResult = void Function(TranscriptionResult result);

class SubtitleEditorPage extends StatefulWidget {
  const SubtitleEditorPage({
    super.key,
    required this.initialResult,
    required this.onSave,
    this.player,
  });

  final TranscriptionResult initialResult;
  final SaveSubtitleResult onSave;
  final VideoPlaybackController? player;

  @override
  State<SubtitleEditorPage> createState() => _SubtitleEditorPageState();
}

class _SubtitleEditorPageState extends State<SubtitleEditorPage> {
  late final SubtitleEditorController _editor;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _editor = SubtitleEditorController(initial: widget.initialResult);
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  void _runEdit(void Function() action) {
    try {
      action();
      setState(() => _errorText = null);
    } on SubtitleEditException catch (error) {
      setState(() => _errorText = error.message);
    } on Object catch (error) {
      setState(() => _errorText = '$error');
    }
  }

  void _save() {
    try {
      widget.onSave(_editor.result);
      Navigator.of(context).pop();
    } on Object catch (error) {
      setState(() => _errorText = '$error');
    }
  }

  Future<void> _split(int index) async {
    final Segment segment = _editor.result.segments[index];
    final TextEditingController offset = TextEditingController(
      text: (segment.text.trim().length ~/ 2).clamp(1, segment.text.trim().length - 1).toString(),
    );
    final TextEditingController time = TextEditingController(
      text: ((segment.start + segment.end) / 2).toStringAsFixed(3),
    );
    final _SplitRequest? request = await showDialog<_SplitRequest>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('拆分第 ${index + 1} 条字幕'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              key: const Key('subtitleSplitOffset'),
              controller: offset,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '左侧字数'),
            ),
            TextField(
              key: const Key('subtitleSplitTime'),
              controller: time,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '分割时间（秒）'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            key: const Key('subtitleSplitConfirm'),
            onPressed: () {
              final int? parsedOffset = int.tryParse(offset.text.trim());
              final double? parsedTime = double.tryParse(time.text.trim());
              if (parsedOffset == null || parsedTime == null) return;
              Navigator.pop(context, _SplitRequest(parsedOffset, parsedTime));
            },
            child: const Text('拆分'),
          ),
        ],
      ),
    );
    offset.dispose();
    time.dispose();
    if (!mounted || request == null) return;
    _runEdit(
      () => _editor.splitSegment(
        index,
        characterOffset: request.offset,
        splitTime: request.time,
      ),
    );
  }

  void _seek(double seconds) {
    final VideoPlaybackController? player = widget.player;
    if (player == null) return;
    unawaited(player.seek(Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round())));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('字幕校对')),
      body: ListenableBuilder(
        listenable: _editor,
        builder: (BuildContext context, Widget? _) {
          final List<Segment> segments = _editor.result.segments;
          return Column(
            children: <Widget>[
              _EditorToolbar(
                editor: _editor,
                errorText: _errorText,
                onUndo: _editor.undo,
                onRedo: _editor.redo,
                onSave: _save,
              ),
              Expanded(
                child: segments.isEmpty
                    ? const Center(child: Text('没有可校对的字幕'))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                        itemCount: segments.length,
                        itemBuilder: (BuildContext context, int index) {
                          final Segment segment = segments[index];
                          return _EditableSegmentTile(
                            key: ValueKey<String>('subtitleRow_$index'),
                            segment: segment,
                            canMerge: index + 1 < segments.length,
                            canSplit: segment.text.trim().length >= 2,
                            onSeek: widget.player == null ? null : () => _seek(segment.start),
                            onApply: (String text, double start, double end) => _runEdit(
                              () => _editor.updateSegment(index, text: text, start: start, end: end),
                            ),
                            onMerge: () => _runEdit(() => _editor.mergeSegments(index)),
                            onSplit: () => _split(index),
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
}

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.editor,
    required this.errorText,
    required this.onUndo,
    required this.onRedo,
    required this.onSave,
  });

  final SubtitleEditorController editor;
  final String? errorText;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Row(
          children: <Widget>[
            IconButton(
              key: const Key('subtitleUndo'),
              tooltip: '撤销',
              onPressed: editor.canUndo ? onUndo : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              key: const Key('subtitleRedo'),
              tooltip: '重做',
              onPressed: editor.canRedo ? onRedo : null,
              icon: const Icon(Icons.redo),
            ),
            Expanded(
              child: errorText == null
                  ? Text('${editor.result.length} 条字幕', textAlign: TextAlign.center)
                  : Text(
                      errorText!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
            ),
            FilledButton.icon(
              key: const Key('subtitleSave'),
              onPressed: onSave,
              icon: const Icon(Icons.check),
              label: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditableSegmentTile extends StatefulWidget {
  const _EditableSegmentTile({
    super.key,
    required this.segment,
    required this.canMerge,
    required this.canSplit,
    required this.onApply,
    required this.onMerge,
    required this.onSplit,
    this.onSeek,
  });

  final Segment segment;
  final bool canMerge;
  final bool canSplit;
  final VoidCallback? onSeek;
  final void Function(String text, double start, double end) onApply;
  final VoidCallback onMerge;
  final VoidCallback onSplit;

  @override
  State<_EditableSegmentTile> createState() => _EditableSegmentTileState();
}

class _EditableSegmentTileState extends State<_EditableSegmentTile> {
  late final TextEditingController _text;
  late final TextEditingController _start;
  late final TextEditingController _end;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.segment.text);
    _start = TextEditingController(text: widget.segment.start.toStringAsFixed(3));
    _end = TextEditingController(text: widget.segment.end.toStringAsFixed(3));
  }

  @override
  void didUpdateWidget(covariant _EditableSegmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_text.text != widget.segment.text) _text.text = widget.segment.text;
    final String start = widget.segment.start.toStringAsFixed(3);
    final String end = widget.segment.end.toStringAsFixed(3);
    if (_start.text != start) _start.text = start;
    if (_end.text != end) _end.text = end;
  }

  @override
  void dispose() {
    _text.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _apply() {
    final double? start = double.tryParse(_start.text.trim());
    final double? end = double.tryParse(_end.text.trim());
    if (start == null || end == null) return;
    widget.onApply(_text.text, start, end);
  }

  @override
  Widget build(BuildContext context) {
    final int index = widget.segment.index;
    return Card(
      key: Key('subtitleCard_$index'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('第 ${index + 1} 条', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                if (widget.onSeek != null)
                  IconButton(
                    key: Key('subtitleSeek_$index'),
                    tooltip: '定位到此处',
                    onPressed: widget.onSeek,
                    icon: const Icon(Icons.my_location_outlined),
                  ),
                IconButton(
                  key: Key('subtitleApply_$index'),
                  tooltip: '应用修改',
                  onPressed: _apply,
                  icon: const Icon(Icons.done),
                ),
                if (widget.canMerge)
                  IconButton(
                    key: Key('subtitleMerge_$index'),
                    tooltip: '与下一条合并',
                    onPressed: widget.onMerge,
                    icon: const Icon(Icons.merge),
                  ),
                if (widget.canSplit)
                  IconButton(
                    key: Key('subtitleSplit_$index'),
                    tooltip: '拆分此条',
                    onPressed: widget.onSplit,
                    icon: const Icon(Icons.call_split),
                  ),
              ],
            ),
            TextField(
              key: Key('subtitleText_$index'),
              controller: _text,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '字幕文本'),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: Key('subtitleStart_$index'),
                    controller: _start,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: '开始（秒）'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: Key('subtitleEnd_$index'),
                    controller: _end,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: '结束（秒）'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SplitRequest {
  const _SplitRequest(this.offset, this.time);

  final int offset;
  final double time;
}
