/// 剪辑工作台主视图：视听监视器与智能字幕就地编辑双栏联动。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_controller.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/ui/studio/studio_header_bar.dart';
import 'package:vsasr_app/src/ui/studio/waveform_timeline_dialog.dart';
import 'package:vsasr_app/src/ui/studio/range_retranscription_dialog.dart';
import 'package:vsasr_app/src/ui/studio/studio_subtitle_panel.dart';
import 'package:vsasr_app/src/ui/studio/studio_video_monitor.dart';
import 'package:vsasr_app/src/ui/theme/studio_theme.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

class StudioWorkspace extends StatefulWidget {
  const StudioWorkspace({
    super.key,
    required this.controller,
    required this.videoController,
    required this.onOpen,
    required this.onOpenProject,
    required this.recentProjects,
    required this.onOpenRecentProject,
    required this.onSaveProject,
    required this.onExport,
    required this.onEdit,
    required this.onTranslate,
    required this.onDiarize,
    required this.onImport,
    required this.onBatch,
    required this.onDiagnostics,
    required this.onHistory,
    required this.historyAvailable,
    this.batchBusy = false,
    this.settings,
    this.translationProviderResolver,
  });

  final TranscribeController controller;
  final VideoPlaybackController videoController;
  final VoidCallback onOpen;
  final VoidCallback onOpenProject;
  final List<String> recentProjects;
  final ValueChanged<String> onOpenRecentProject;
  final VoidCallback onSaveProject;
  final VoidCallback onExport;
  final VoidCallback onEdit;
  final VoidCallback onTranslate;
  final VoidCallback onDiarize;
  final VoidCallback onImport;
  final VoidCallback onBatch;
  final VoidCallback onDiagnostics;
  final VoidCallback onHistory;
  final bool historyAvailable;
  final bool batchBusy;
  final AppSettingsRepository? settings;
  final Future<TranslationProvider?> Function()? translationProviderResolver;

  @override
  State<StudioWorkspace> createState() => _StudioWorkspaceState();
}

class _StudioWorkspaceState extends State<StudioWorkspace> {
  SubtitleEditorController? _editor;
  bool _timelineOpen = false;
  VideoSubtitleDisplayMode _displayMode = VideoSubtitleDisplayMode.bilingual;
  final Set<_StudioSegmentIdentity> _retryingTranslation =
      <_StudioSegmentIdentity>{};
  int _subtitleGeneration = 0;
  TranscriptionResult? _sourceResult;
  String? _sourcePath;

  @override
  void initState() {
    super.initState();
    _syncWithController();
    widget.controller.addListener(_onControllerTick);
  }

  @override
  void didUpdateWidget(StudioWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerTick);
      widget.controller.addListener(_onControllerTick);
      _sourceResult = null;
      _editor?.dispose();
      _editor = null;
    }
    _syncWithController();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerTick);
    _editor?.dispose();
    super.dispose();
  }

  void _onControllerTick() {
    if (!mounted) return;
    _syncWithController();
    setState(() {});
  }

  void _syncWithController() {
    final String? currentPath = widget.controller.filePath;
    if (currentPath != null &&
        !widget.controller.busy &&
        widget.videoController.filePath != currentPath &&
        File(currentPath).existsSync()) {
      unawaited(widget.videoController.open(currentPath));
    }

    final TranscriptionResult? result = widget.controller.result;
    if (!identical(_sourceResult, result) || _sourcePath != currentPath) {
      _subtitleGeneration++;
      _sourceResult = result;
      _sourcePath = currentPath;
      if (result != null) {
        if (identical(_editor?.result, result)) return;
        _editor?.dispose();
        _editor = SubtitleEditorController(initial: result);
      } else {
        _editor?.dispose();
        _editor = null;
      }
    }
  }

  void _commitEditorChange() {
    if (_editor == null) return;
    // 同步到转写控制器
    _subtitleGeneration++;
    widget.controller.applyEditedResult(_editor!.result);
    setState(() {});
  }

  void _historyEdit({required bool undo}) {
    if (widget.controller.busy || _editor == null) return;
    if (undo) {
      _editor!.undo();
    } else {
      _editor!.redo();
    }
    _commitEditorChange();
  }

  Future<void> _openWaveform() async {
    final editor = _editor;
    final controller = widget.controller;
    final player = widget.videoController;
    final path = controller.filePath;
    if (editor == null || path == null || controller.busy || widget.batchBusy) {
      return;
    }
    if (player.filePath != path ||
        player.duration <= Duration.zero ||
        player.busy) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请等待当前媒体加载完成后打开时间轴')));
      return;
    }
    final duration = player.duration.inMicroseconds / 1000000;
    setState(() {
      _timelineOpen = true;
    });
    WaveformSelection? selection;
    try {
      selection = await showDialog<WaveformSelection>(
        context: context,
        builder: (_) => WaveformTimelineDialog(
          player: player,
          path: path,
          duration: duration,
          result: () => editor.result,
          onTimingChanged: (index, start, end) {
            if (!mounted ||
                controller.busy ||
                !identical(editor, _editor) ||
                controller.filePath != path) {
              throw const SubtitleEditException('媒体或字幕已变化，请重新打开时间轴');
            }
            editor.updateSegment(
              index,
              start: start,
              end: end,
              mediaDuration: duration,
            );
            _commitEditorChange();
          },
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _timelineOpen = false;
        });
      }
    }
    if (!mounted ||
        selection == null ||
        !identical(editor, _editor) ||
        controller.filePath != path) {
      return;
    }
    await _retranscribeRange(start: selection.start, end: selection.end);
  }

  Future<void> _retranscribeRange({double? start, double? end}) async {
    final editor = _editor;
    final controller = widget.controller;
    if (editor == null || controller.busy || controller.filePath == null) {
      return;
    }
    final source = editor.result;
    final path = controller.filePath;
    final video = widget.videoController;
    final double? mediaDuration =
        video.filePath == path && video.duration > Duration.zero
        ? video.duration.inMicroseconds / 1000000
        : null;
    final replacement = await showDialog<RangeReplacement>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RangeRetranscriptionDialog(
        controller: controller,
        initial: source,
        mediaDuration: mediaDuration,
        position:
            start ?? widget.videoController.position.inMicroseconds / 1000000,
        initialEnd: end,
      ),
    );
    if (!mounted || replacement == null) return;
    if (!identical(editor, _editor) ||
        !identical(source, editor.result) ||
        path != controller.filePath ||
        controller.busy) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('字幕或媒体已变化，请重新选择范围')));
      return;
    }
    try {
      editor.replaceRange(
        replacement.start,
        replacement.end,
        replacement.segments,
        mediaDuration: mediaDuration,
      );
      _commitEditorChange();
    } on SubtitleEditException catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _replaceText() async {
    final SubtitleEditorController? editor = _editor;
    if (editor == null || widget.controller.busy) return;
    final TextEditingController search = TextEditingController();
    final TextEditingController replacement = TextEditingController();
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('搜索替换原文'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              key: const Key('studioReplaceSearch'),
              controller: search,
              decoration: const InputDecoration(labelText: '查找内容'),
            ),
            TextField(
              key: const Key('studioReplaceValue'),
              controller: replacement,
              decoration: const InputDecoration(labelText: '替换为'),
            ),
            const Text('修改原文会清除对应旧译文，可撤销。'),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('studioReplaceConfirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('全部替换'),
          ),
        ],
      ),
    );
    final String needle = search.text;
    final String value = replacement.text;
    // 对话框退场动画期间 TextField 仍可能访问 controller。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      search.dispose();
      replacement.dispose();
    });
    if (!mounted ||
        confirmed != true ||
        widget.controller.busy ||
        !identical(editor, _editor)) {
      return;
    }
    try {
      final int count = editor.replaceText(query: needle, replacement: value);
      if (count > 0) _commitEditorChange();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已替换 $count 处')));
    } on Object catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('替换失败：$error')));
    }
  }

  Future<void> _showReadingIssues() async {
    final SubtitleEditorController? editor = _editor;
    if (editor == null) return;
    final issues = editor.checkQuality();
    final ({int index, bool retranscribe})?
    action = await showDialog<({int index, bool retranscribe})>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('字幕质量检查'),
        content: SizedBox(
          width: 480,
          height: issues.isEmpty ? 60 : 300,
          child: issues.isEmpty
              ? const Text('没有发现需要人工确认的字幕问题。')
              : ListView.builder(
                  itemCount: issues.length,
                  itemBuilder: (BuildContext context, int i) {
                    final SubtitleQualityIssue issue = issues[i];
                    return ListTile(
                      title: Text(
                        '第 ${issue.index + 1} 条 · ${_qualityIssueLabel(issue.kind)}',
                      ),
                      subtitle: Text(issue.message),
                      onTap: () => Navigator.pop(context, (
                        index: i,
                        retranscribe: false,
                      )),
                      trailing: IconButton(
                        tooltip: '用此范围重新识别',
                        onPressed: widget.controller.filePath == null
                            ? null
                            : () => Navigator.pop(context, (
                                index: i,
                                retranscribe: true,
                              )),
                        icon: const Icon(Icons.refresh),
                      ),
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || !identical(editor, _editor)) return;
    final issue = issues[action.index];
    if (action.retranscribe) {
      await _retranscribeRange(start: issue.start, end: issue.end);
      return;
    }
    await widget.videoController.seek(
      Duration(microseconds: (issue.start * 1000000).round()),
    );
  }

  String _qualityIssueLabel(SubtitleQualityIssueKind kind) => switch (kind) {
    SubtitleQualityIssueKind.overlap => '时间重叠',
    SubtitleQualityIssueKind.readingSpeed => '阅读过快',
    SubtitleQualityIssueKind.longGap => '长空白',
    SubtitleQualityIssueKind.emptyText => '空文本',
    SubtitleQualityIssueKind.duplicateText => '重复文本',
    SubtitleQualityIssueKind.languageMismatch => '疑似语言错误',
  };

  void _handleUpdateSegment(
    int index, {
    String? text,
    double? start,
    double? end,
    String? speaker,
  }) {
    if (_editor == null) return;
    try {
      _editor!.updateSegment(
        index,
        text: text,
        start: start,
        end: end,
        speaker: speaker,
      );
      _commitEditorChange();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('修改字幕失败：$error')));
    }
  }

  void _handleUpdateTranslation(int index, String? translation) {
    if (_editor == null) return;
    try {
      _editor!.updateTranslation(index, translation);
      _commitEditorChange();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('修改译文失败：$error')));
    }
  }

  void _handleSplitSegment(
    int index, {
    required int characterOffset,
    required double splitTime,
  }) {
    if (_editor == null) return;
    try {
      _editor!.splitSegment(
        index,
        characterOffset: characterOffset,
        splitTime: splitTime,
      );
      _commitEditorChange();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('拆分字幕失败：$error')));
    }
  }

  void _handleMergeSegments(int index) {
    if (_editor == null) return;
    try {
      _editor!.mergeSegments(index);
      _commitEditorChange();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('合并字幕失败：$error')));
    }
  }

  void _handleDeleteSegment(int index) {
    if (_editor == null) return;
    try {
      _editor!.deleteSegment(index);
      _commitEditorChange();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除字幕失败：$error')));
    }
  }

  Future<void> _retrySingleTranslation(Segment segment) async {
    final Future<TranslationProvider?> Function()? resolver =
        widget.translationProviderResolver;
    if (resolver == null) return;
    final _StudioSegmentIdentity identity = _StudioSegmentIdentity.fromSegment(
      segment,
    );
    if (_retryingTranslation.contains(identity)) return;
    final int generation = _subtitleGeneration;
    setState(() => _retryingTranslation.add(identity));
    TranslationProvider? provider;
    try {
      final TranslationApiSettings settings =
          await (widget.settings ?? AppSettingsRepository())
              .loadTranslationApiSettings();
      provider = await resolver();
      if (provider == null) {
        if (mounted && _subtitleGeneration == generation) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请先在设置中保存第三方翻译 API Key')),
          );
        }
        return;
      }
      final List<String> translated = await translateTexts(
        provider,
        <String>[segment.text],
        from: segment.language.trim().isEmpty ? null : segment.language,
        to: settings.targetLanguage,
        isCancelled: () =>
            !mounted || _subtitleGeneration != generation || _editor == null,
      );
      final Segment? current = _findCurrentSegment(identity);
      if (!mounted || current == null || _subtitleGeneration != generation) {
        return;
      }
      _handleUpdateTranslation(current.index, translated.single);
    } on TranslationCancelledException {
      // 编辑或离开页面后丢弃迟到结果，不显示为服务故障。
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('单句翻译失败：$error')));
    } finally {
      if (provider is ClosableTranslationProvider) provider.close();
      if (mounted) {
        setState(() => _retryingTranslation.remove(identity));
      }
    }
  }

  Segment? _findCurrentSegment(_StudioSegmentIdentity identity) {
    final List<Segment>? segments = _editor?.result.segments;
    if (segments == null) return null;
    for (final Segment candidate in segments) {
      if (identity.matches(candidate)) return candidate;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final TranscribeController c = widget.controller;
    final TranscriptionResult? result = _editor?.result ?? c.result;
    final List<Segment> segments = result?.segments ?? const <Segment>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 顶部操作栏
        StudioHeaderBar(
          controller: c,
          onOpen: widget.onOpen,
          onOpenProject: widget.onOpenProject,
          recentProjects: widget.recentProjects,
          onOpenRecentProject: widget.onOpenRecentProject,
          onSaveProject: widget.onSaveProject,
          onExport: widget.onExport,
          onEdit: widget.onEdit,
          onTranslate: widget.onTranslate,
          onDiarize: widget.onDiarize,
          onImport: widget.onImport,
          onBatch: widget.onBatch,
          onDiagnostics: widget.onDiagnostics,
          onHistory: widget.onHistory,
          historyAvailable: widget.historyAvailable,
          batchBusy: widget.batchBusy,
        ),
        if (_editor != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Wrap(
                spacing: 8,
                children: <Widget>[
                  TextButton.icon(
                    key: const Key('studioUndo'),
                    onPressed: !c.busy && _editor!.canUndo
                        ? () => _historyEdit(undo: true)
                        : null,
                    icon: const Icon(Icons.undo),
                    label: const Text('撤销'),
                  ),
                  TextButton.icon(
                    key: const Key('studioRedo'),
                    onPressed: !c.busy && _editor!.canRedo
                        ? () => _historyEdit(undo: false)
                        : null,
                    icon: const Icon(Icons.redo),
                    label: const Text('重做'),
                  ),
                  TextButton.icon(
                    key: const Key('studioWaveform'),
                    onPressed: c.busy || widget.batchBusy || c.filePath == null
                        ? null
                        : _openWaveform,
                    icon: const Icon(Icons.graphic_eq),
                    label: const Text('波形时间轴'),
                  ),
                  TextButton.icon(
                    key: const Key('studioRetranscribeRange'),
                    onPressed: c.busy || widget.batchBusy || c.filePath == null
                        ? null
                        : _retranscribeRange,
                    icon: const Icon(Icons.refresh),
                    label: const Text('选区重新识别'),
                  ),
                  TextButton.icon(
                    key: const Key('studioReplace'),
                    onPressed: c.busy ? null : _replaceText,
                    icon: const Icon(Icons.find_replace),
                    label: const Text('搜索替换'),
                  ),
                  TextButton.icon(
                    key: const Key('studioReadingSpeed'),
                    onPressed: _showReadingIssues,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('字幕质量检查'),
                  ),
                ],
              ),
            ),
          ),
        // 错误提示条
        if (c.errorText != null)
          Container(
            color: StudioColors.errorSubtle,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.error_outline,
                  size: 16,
                  color: StudioColors.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.errorText!,
                    style: const TextStyle(
                      color: StudioColors.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 双栏 Studio 工作区
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool isWide = constraints.maxWidth >= 720;
              final Widget monitor = StudioVideoMonitor(
                controller: widget.videoController,
                segments: segments,
                suspendLoop: _timelineOpen,
                displayMode: _displayMode,
                onDisplayModeChanged: (VideoSubtitleDisplayMode mode) {
                  setState(() => _displayMode = mode);
                },
                onOpenMedia: widget.onOpen,
                onSegmentSelected: (Segment s) {
                  unawaited(
                    widget.videoController.seek(
                      Duration(
                        microseconds: (s.start * Duration.microsecondsPerSecond)
                            .round(),
                      ),
                    ),
                  );
                },
              );

              final Widget subtitlePanel = IgnorePointer(
                ignoring: c.busy,
                child: StudioSubtitlePanel(
                  segments: segments,
                  videoController: widget.videoController,
                  onSeek: (Duration pos) {
                    unawaited(widget.videoController.seek(pos));
                  },
                  onUpdateSegment: _handleUpdateSegment,
                  onUpdateTranslation: _handleUpdateTranslation,
                  onSplitSegment: _handleSplitSegment,
                  onMergeSegments: _handleMergeSegments,
                  onDeleteSegment: _handleDeleteSegment,
                  onRetryTranslation: _retrySingleTranslation,
                  canRetryTranslation: (_) =>
                      widget.translationProviderResolver != null,
                  isRetryingTranslation: (Segment s) => _retryingTranslation
                      .contains(_StudioSegmentIdentity.fromSegment(s)),
                ),
              );

              if (isWide) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // 左侧视频监视器
                      Expanded(flex: 6, child: monitor),
                      const SizedBox(width: 14),
                      // 右侧字幕编辑列表
                      Expanded(flex: 5, child: subtitlePanel),
                    ],
                  ),
                );
              } else {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      SizedBox(height: 240, child: monitor),
                      const SizedBox(height: 10),
                      Expanded(child: subtitlePanel),
                    ],
                  ),
                );
              }
            },
          ),
        ),
        // 底部统计栏
        if (result != null && !result.isEmpty)
          _StudioFooter(controller: c, result: result),
      ],
    );
  }
}

/// 单句翻译等待期间用于确认字幕是否仍是同一条的不可变快照。
class _StudioSegmentIdentity {
  const _StudioSegmentIdentity._(
    this.text,
    this.start,
    this.end,
    this.language,
  );

  factory _StudioSegmentIdentity.fromSegment(Segment segment) =>
      _StudioSegmentIdentity._(
        segment.text,
        segment.start,
        segment.end,
        segment.language,
      );

  final String text;
  final double start;
  final double end;
  final String language;

  bool matches(Segment segment) =>
      segment.text == text &&
      segment.start == start &&
      segment.end == end &&
      segment.language == language;

  @override
  bool operator ==(Object other) =>
      other is _StudioSegmentIdentity &&
      other.text == text &&
      other.start == start &&
      other.end == end &&
      other.language == language;

  @override
  int get hashCode => Object.hash(text, start, end, language);
}

class _StudioFooter extends StatelessWidget {
  const _StudioFooter({required this.controller, required this.result});

  final TranscribeController controller;
  final TranscriptionResult result;

  @override
  Widget build(BuildContext context) {
    final Duration? elapsed = controller.elapsed;
    final String rtf = elapsed == null || result.duration <= 0
        ? ''
        : '　RTF ${(elapsed.inMilliseconds / 1000 / result.duration).toStringAsFixed(3)}';

    return Container(
      decoration: const BoxDecoration(
        color: StudioColors.surfaceSubtle,
        border: Border(top: BorderSide(color: StudioColors.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        '${result.length} 段　音频 ${result.duration.toStringAsFixed(2)}s'
        '${elapsed == null ? '' : '　耗时 ${(elapsed.inMilliseconds / 1000).toStringAsFixed(2)}s'}'
        '$rtf',
        style: const TextStyle(fontSize: 12, color: StudioColors.textSecondary),
      ),
    );
  }
}
