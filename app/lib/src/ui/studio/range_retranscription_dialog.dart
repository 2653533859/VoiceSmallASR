/// 选区识别参数与新旧字幕预览。确认前不修改编辑器。
library;

import 'package:flutter/material.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

class RangeReplacement {
  const RangeReplacement(this.start, this.end, this.segments);
  final double start;
  final double end;
  final List<Segment> segments;
}

class RangeRetranscriptionDialog extends StatefulWidget {
  const RangeRetranscriptionDialog({
    super.key,
    required this.controller,
    required this.initial,
    required this.position,
    this.mediaDuration,
  });
  final TranscribeController controller;
  final TranscriptionResult initial;
  final double position;
  final double? mediaDuration;

  @override
  State<RangeRetranscriptionDialog> createState() =>
      _RangeRetranscriptionDialogState();
}

class _RangeRetranscriptionDialogState
    extends State<RangeRetranscriptionDialog> {
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final SubtitleEditorController _bounds;
  late AsrConfig _config;
  RangeReplacement? _preview;
  bool _running = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bounds = SubtitleEditorController(initial: widget.initial);
    final double start = widget.position.clamp(
      0,
      (widget.mediaDuration ?? widget.initial.duration),
    );
    _start = TextEditingController(text: start.toStringAsFixed(3));
    _end = TextEditingController(
      text: (start + 10)
          .clamp(0, (widget.mediaDuration ?? widget.initial.duration))
          .toStringAsFixed(3),
    );
    _config = widget.controller.config;
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _bounds.dispose();
    super.dispose();
  }

  ({double start, double end}) _range() => _bounds.resolveRange(
    double.tryParse(_start.text) ?? double.nan,
    double.tryParse(_end.text) ?? double.nan,
    mediaDuration: widget.mediaDuration,
  );

  Future<void> _recognize() async {
    setState(() {
      _error = null;
      _preview = null;
    });
    try {
      final range = _range();
      if (range.end - range.start > 120) {
        throw const SubtitleEditException('扩展后的选区不能超过 120 秒');
      }
      setState(() {
        _running = true;
      });
      final segments = await widget.controller.previewRange(
        start: range.start,
        end: range.end,
        config: _config,
        mediaDuration: widget.mediaDuration,
        isCancelled: () => !mounted,
      );
      if (!mounted) return;
      setState(() {
        if (segments.isEmpty) {
          _error = '没有识别到语音，原字幕保持不变。可调整参数后重试。';
        } else {
          _preview = RangeReplacement(range.start, range.end, segments);
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    String rangeText;
    List<Segment> old = const [];
    try {
      final range = _range();
      rangeText =
          '实际范围：${range.start.toStringAsFixed(3)}–${range.end.toStringAsFixed(3)} 秒';
      old = widget.initial.segments
          .where((s) => s.end > range.start && s.start < range.end)
          .toList();
    } catch (_) {
      rangeText = '请输入有效起止时间';
    }
    return AlertDialog(
      title: const Text('选区重新识别'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('输入秒数，单次最多 120 秒。范围会扩展到完整字幕边界；本次参数不会更改全局设置。'),
              TextField(
                key: const Key('rangeStart'),
                controller: _start,
                enabled: !_running,
                decoration: const InputDecoration(labelText: '开始时间（秒）'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {
                  _preview = null;
                }),
              ),
              TextField(
                key: const Key('rangeEnd'),
                controller: _end,
                enabled: !_running,
                decoration: const InputDecoration(labelText: '结束时间（秒）'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {
                  _preview = null;
                }),
              ),
              Text(rangeText),
              DropdownButtonFormField<String>(
                initialValue: _config.language,
                decoration: const InputDecoration(labelText: '识别语言（原音频）'),
                items: kLanguages
                    .map(
                      (l) => DropdownMenuItem(
                        value: l,
                        child: Text(kLanguageLabels[l]!),
                      ),
                    )
                    .toList(),
                onChanged: _running
                    ? null
                    : (value) => setState(() {
                        _config = _config.copyWith(language: value);
                        _preview = null;
                      }),
              ),
              Text('输入增益：+${_config.inputGainDb.toStringAsFixed(0)} dB'),
              Slider(
                value: _config.inputGainDb,
                min: 0,
                max: 12,
                divisions: 12,
                onChanged: _running
                    ? null
                    : (value) => setState(() {
                        _config = _config.copyWith(inputGainDb: value);
                        _preview = null;
                      }),
              ),
              Text('语音检测阈值：${_config.vad.threshold.toStringAsFixed(2)}'),
              Slider(
                value: _config.vad.threshold.clamp(.1, .9),
                min: .1,
                max: .9,
                divisions: 16,
                onChanged: _running
                    ? null
                    : (value) => setState(() {
                        _config = _config.copyWith(
                          vad: _config.vad.copyWith(threshold: value),
                        );
                        _preview = null;
                      }),
              ),
              TextButton(
                onPressed: _running
                    ? null
                    : () => setState(() {
                        _config = _config.copyWith(
                          inputGainDb: 6,
                          vad: _config.vad.copyWith(
                            threshold: .35,
                            minSilenceDuration: .5,
                            minSpeechDuration: .15,
                          ),
                        );
                        _preview = null;
                      }),
                child: const Text('应用小声语音预设'),
              ),
              if (_running) const LinearProgressIndicator(),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 12),
              const Text('原字幕'),
              Text(
                old.isEmpty
                    ? '（选区没有字幕）'
                    : old
                          .map(
                            (s) =>
                                '${s.start.toStringAsFixed(2)}–${s.end.toStringAsFixed(2)}  ${s.text}',
                          )
                          .join('\n'),
              ),
              if (_preview != null) ...[
                const Divider(),
                const Text('新字幕（替换后需重新翻译，可撤销）'),
                Text(
                  _preview!.segments
                      .map(
                        (s) =>
                            '${s.start.toStringAsFixed(2)}–${s.end.toStringAsFixed(2)}  ${s.text}',
                      )
                      .join('\n'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_running ? '取消识别' : '取消'),
        ),
        TextButton(
          onPressed: _running ? null : _recognize,
          child: const Text('识别并预览'),
        ),
        FilledButton(
          onPressed: _running || _preview == null
              ? null
              : () => Navigator.pop(context, _preview),
          child: const Text('确认替换'),
        ),
      ],
    );
  }
}
