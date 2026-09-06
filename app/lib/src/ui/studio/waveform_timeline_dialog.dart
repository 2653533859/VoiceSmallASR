/// 波形窗口、选区和字幕边界编辑。媒体按需分块解码。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/waveform.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

class WaveformSelection {
  const WaveformSelection(this.start, this.end);
  final double start;
  final double end;
}

typedef WaveformLoader = Future<WaveformData> Function({
  required String path,
  required double start,
  required double duration,
  bool Function()? isCancelled,
});

class WaveformTimelineDialog extends StatefulWidget {
  const WaveformTimelineDialog({
    super.key,
    required this.player,
    required this.path,
    required this.duration,
    required this.result,
    required this.onTimingChanged,
    this.loader = loadWaveform,
  });
  final VideoPlaybackController player;
  final String path;
  final double duration;
  final TranscriptionResult Function() result;
  final void Function(int index, double start, double end) onTimingChanged;
  final WaveformLoader loader;

  @override
  State<WaveformTimelineDialog> createState() => _WaveformTimelineDialogState();
}

class _WaveformTimelineDialogState extends State<WaveformTimelineDialog> {
  double _start = 0;
  double _span = 30;
  double? _anchor;
  WaveformSelection? _selection;
  WaveformData? _waveform;
  String? _error;
  bool _loading = false;
  bool _looping = false;
  int _generation = 0;
  int? _editingIndex;
  double? _draftStart;
  double? _draftEnd;

  double get _end => math.min(widget.duration, _start + _span);
  double get _widthSeconds => _end - _start;

  @override
  void initState() {
    super.initState();
    _start = widget.player.position.inMicroseconds / 1000000;
    _start = _start.clamp(0, math.max(0, widget.duration - _span));
    widget.player.addListener(_onPlayback);
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _looping = false;
    widget.player.removeListener(_onPlayback);
    super.dispose();
  }

  void _onPlayback() {
    if (!mounted) return;
    final selection = _selection;
    final player = widget.player;
    if (player.filePath != widget.path || player.errorText != null) {
      _looping = false;
    } else if (_looping &&
        selection != null &&
        player.playing &&
        !player.seeking) {
      final position = player.actualPosition.inMicroseconds / 1000000;
      if (position >= selection.end || position < selection.start) {
        unawaited(
          player.seek(
            Duration(microseconds: (selection.start * 1000000).round()),
          ),
        );
      }
    }
    setState(() {});
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _waveform = null;
      _error = null;
    });
    try {
      final data = await widget.loader(
        path: widget.path,
        start: _start,
        duration: _widthSeconds,
        isCancelled: () => !mounted || generation != _generation,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _waveform = data;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = '波形加载失败：$error';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _move(double start) {
    setState(() {
      _start = start.clamp(0, math.max(0, widget.duration - _span));
      _selection = null;
      _looping = false;
    });
    unawaited(_load());
  }

  double _time(double x, double width) =>
      _start + (x / width).clamp(0, 1) * _widthSeconds;

  void _select(double x, double width, {bool begin = false}) {
    final time = _time(x, width);
    setState(() {
      if (begin) {
        _anchor = time;
        _looping = false;
      }
      final anchor = _anchor ?? time;
      _selection = WaveformSelection(
        math.min(anchor, time),
        math.max(anchor, time),
      );
    });
  }

  Future<void> _toggleLoop() async {
    final selection = _selection;
    if (selection == null || selection.end - selection.start < .1) return;
    setState(() {
      _looping = !_looping;
    });
    if (!_looping) return;
    await widget.player.seek(
      Duration(microseconds: (selection.start * 1000000).round()),
    );
    if (!mounted || !_looping || widget.player.filePath != widget.path) return;
    if (!widget.player.playing) await widget.player.playOrPause();
  }

  void _dragBoundary(int index, bool left, double delta, double width) {
    final segment = widget.result().segments[index];
    final gap = math.min(.01, segment.duration / 2);
    setState(() {
      if (_editingIndex != index) {
        _editingIndex = index;
        _draftStart = segment.start;
        _draftEnd = segment.end;
      }
      if (left) {
        _draftStart = (_draftStart! + delta / width * _widthSeconds).clamp(
          0,
          _draftEnd! - gap,
        );
      } else {
        _draftEnd = (_draftEnd! + delta / width * _widthSeconds).clamp(
          _draftStart! + gap,
          widget.duration,
        );
      }
    });
  }

  void _commitBoundary() {
    final index = _editingIndex;
    if (index == null) return;
    try {
      widget.onTimingChanged(index, _draftStart!, _draftEnd!);
      _error = null;
    } catch (error) {
      _error = '$error';
    }
    setState(() {
      _editingIndex = null;
      _draftStart = null;
      _draftEnd = null;
    });
  }

  String _label(double seconds) {
    final value = (seconds * 100).round();
    return '${value ~/ 6000}:${((value ~/ 100) % 60).toString().padLeft(2, '0')}.${(value % 100).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final selection = _selection;
    final canSelect =
        selection != null && selection.end - selection.start >= .1;
    final mediaMatches =
        widget.player.filePath == widget.path && !widget.player.busy;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('音频波形与字幕时间轴', style: TextStyle(fontSize: 20)),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const Text('拖动上方波形选择范围；拖动下方字幕两侧手柄调整起止时间。边界修改可在 Studio 撤销。'),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      key: const Key('waveformPrevious'),
                      tooltip: '上一窗口',
                      onPressed: _start <= 0
                          ? null
                          : () => _move(_start - _span),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text('${_label(_start)} – ${_label(_end)}'),
                    IconButton(
                      key: const Key('waveformNext'),
                      tooltip: '下一窗口',
                      onPressed: _end >= widget.duration
                          ? null
                          : () => _move(_start + _span),
                      icon: const Icon(Icons.chevron_right),
                    ),
                    DropdownButton<double>(
                      value: _span,
                      items: [15.0, 30.0, 60.0, 120.0]
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text('${v.toInt()} 秒窗口'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        _span = value;
                        _move(_start);
                      },
                    ),
                    TextButton(
                      onPressed: mediaMatches
                          ? () => _move(
                              widget.player.position.inMicroseconds / 1000000,
                            )
                          : null,
                      child: const Text('定位到播放位置'),
                    ),
                  ],
                ),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const Text('原始音量峰值波形（未应用识别增益）'),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final segments = widget.result().segments;
                    return Column(
                      children: [
                        GestureDetector(
                          key: const Key('waveformSelection'),
                          behavior: HitTestBehavior.opaque,
                          dragStartBehavior: DragStartBehavior.down,
                          onTapUp: mediaMatches
                              ? (details) => widget.player.seek(
                                  Duration(
                                    microseconds:
                                        (_time(
                                                  details.localPosition.dx,
                                                  width,
                                                ) *
                                                1000000)
                                            .round(),
                                  ),
                                )
                              : null,
                          onPanStart: (details) => _select(
                            details.localPosition.dx,
                            width,
                            begin: true,
                          ),
                          onPanUpdate: (details) =>
                              _select(details.localPosition.dx, width),
                          child: CustomPaint(
                            size: Size(width, 110),
                            painter: _WaveformPainter(
                              data: _waveform,
                              start: _start,
                              end: _end,
                              selection: selection,
                              position:
                                  widget.player.position.inMicroseconds /
                                  1000000,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 64,
                          child: Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              Positioned.fill(
                                child: ColoredBox(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                ),
                              ),
                              for (
                                int index = 0;
                                index < segments.length;
                                index++
                              )
                                if (segments[index].end > _start &&
                                    segments[index].start < _end)
                                  _subtitleBlock(index, segments[index], width),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  selection == null
                      ? '尚未选择范围'
                      : '选区：${_label(selection.start)} – ${_label(selection.end)}（${(selection.end - selection.start).toStringAsFixed(2)} 秒）',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      key: const Key('waveformLoop'),
                      onPressed: canSelect && mediaMatches ? _toggleLoop : null,
                      icon: Icon(_looping ? Icons.stop : Icons.repeat),
                      label: Text(_looping ? '停止循环' : '循环播放选区'),
                    ),
                    FilledButton(
                      key: const Key('waveformRecognize'),
                      onPressed: canSelect && mediaMatches
                          ? () => Navigator.pop(context, selection)
                          : null,
                      child: const Text('选区重新识别'),
                    ),
                    TextButton(
                      onPressed: _loading ? null : _load,
                      child: const Text('重新加载波形'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _subtitleBlock(int index, Segment segment, double width) {
    final start = _editingIndex == index ? _draftStart! : segment.start;
    final end = _editingIndex == index ? _draftEnd! : segment.end;
    final x = (start - _start) / _widthSeconds * width;
    final right = (end - _start) / _widthSeconds * width;
    final leftVisible = x.clamp(0.0, width);
    final blockWidth = (right.clamp(0, width) - leftVisible).clamp(1.0, width);
    Widget handle(bool left) => GestureDetector(
      key: Key('waveformBoundary-$index-${left ? 'start' : 'end'}'),
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragUpdate: (details) =>
          _dragBoundary(index, left, details.delta.dx, width),
      onHorizontalDragEnd: (_) => _commitBoundary(),
      onHorizontalDragCancel: () => setState(() {
        _editingIndex = null;
      }),
      child: const SizedBox(
        width: 12,
        child: Center(child: Icon(Icons.drag_indicator, size: 12)),
      ),
    );
    return Positioned(
      left: leftVisible,
      width: blockWidth,
      top: 4,
      bottom: 4,
      child: Tooltip(
        message: '${_label(start)}–${_label(end)} ${segment.text}',
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: .18),
            border: Border.all(color: Colors.blue),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: ClipRect(
                    child: Text(
                      segment.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (start >= _start)
                Positioned(left: 0, top: 0, bottom: 0, child: handle(true)),
              if (end <= _end)
                Positioned(right: 0, top: 0, bottom: 0, child: handle(false)),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.data,
    required this.start,
    required this.end,
    required this.selection,
    required this.position,
    required this.color,
  });
  final WaveformData? data;
  final double start, end, position;
  final WaveformSelection? selection;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()..color = Colors.grey,
    );
    final peaks = data?.peaks;
    if (peaks != null) {
      for (int i = 0; i < peaks.length; i++) {
        final x = i / peaks.length * size.width;
        final height = peaks[i] * (size.height - 8) / 2;
        canvas.drawLine(
          Offset(x, size.height / 2 - height),
          Offset(x, size.height / 2 + height),
          paint,
        );
      }
    }
    final range = selection;
    if (range != null) {
      final left =
          ((range.start - start) / (end - start)).clamp(0, 1) * size.width;
      final right =
          ((range.end - start) / (end - start)).clamp(0, 1) * size.width;
      canvas.drawRect(
        Rect.fromLTRB(left, 0, right, size.height),
        Paint()..color = color.withValues(alpha: .18),
      );
    }
    if (position >= start && position <= end) {
      final x = (position - start) / (end - start) * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Colors.red
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) => true;
}
