/// Studio 智能字幕时间轴与就地编辑器。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/ui/theme/studio_theme.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_timeline.dart';

typedef UpdateSegmentCallback =
    void Function(
      int index, {
      String? text,
      double? start,
      double? end,
      String? speaker,
    });

typedef UpdateTranslationCallback =
    void Function(int index, String? translation);

typedef SplitSegmentCallback =
    void Function(
      int index, {
      required int characterOffset,
      required double splitTime,
    });

class StudioSubtitlePanel extends StatefulWidget {
  const StudioSubtitlePanel({
    super.key,
    required this.segments,
    required this.videoController,
    this.onSeek,
    this.onUpdateSegment,
    this.onUpdateTranslation,
    this.onSplitSegment,
    this.onMergeSegments,
    this.onDeleteSegment,
    this.onRetryTranslation,
    this.canRetryTranslation,
    this.isRetryingTranslation,
  });

  final List<Segment> segments;
  final VideoPlaybackController videoController;
  final ValueChanged<Duration>? onSeek;
  final UpdateSegmentCallback? onUpdateSegment;
  final UpdateTranslationCallback? onUpdateTranslation;
  final SplitSegmentCallback? onSplitSegment;
  final ValueChanged<int>? onMergeSegments;
  final ValueChanged<int>? onDeleteSegment;
  final Future<void> Function(Segment segment)? onRetryTranslation;
  final bool Function(Segment segment)? canRetryTranslation;
  final bool Function(Segment segment)? isRetryingTranslation;

  @override
  State<StudioSubtitlePanel> createState() => _StudioSubtitlePanelState();
}

class _StudioSubtitlePanelState extends State<StudioSubtitlePanel> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  String _searchQuery = '';
  String? _selectedSpeakerFilter;
  bool _autoScroll = true;
  int? _editingIndex;
  bool _editingTranslation = false;
  TextEditingController? _editingController;
  int? _lastActiveIndex;

  @override
  void initState() {
    super.initState();
    widget.videoController.addListener(_onVideoTick);
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim());
    });
  }

  @override
  void didUpdateWidget(StudioSubtitlePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoController != widget.videoController) {
      oldWidget.videoController.removeListener(_onVideoTick);
      widget.videoController.addListener(_onVideoTick);
    }
  }

  @override
  void dispose() {
    widget.videoController.removeListener(_onVideoTick);
    _scrollController.dispose();
    _searchController.dispose();
    _editingController?.dispose();
    super.dispose();
  }

  void _onVideoTick() {
    if (!mounted || widget.segments.isEmpty) return;
    final Segment? current = activeSegment(
      widget.segments,
      widget.videoController.position,
    );
    final int? activeIdx = current?.index;
    if (activeIdx != null && activeIdx != _lastActiveIndex) {
      _lastActiveIndex = activeIdx;
      if (_autoScroll && _editingIndex == null && _searchQuery.isEmpty) {
        _scrollToIndex(activeIdx);
      }
      setState(() {});
    }
  }

  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;
    // 粗略估算每个卡片高度约 110px
    const double estimatedCardHeight = 110.0;
    final double targetOffset = (index * estimatedCardHeight) - 80;
    final double clamped = targetOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _showSplitDialog(int index) async {
    final Segment segment = widget.segments[index];
    final int textLength = segment.text.trim().length;
    if (textLength < 2) return;
    final TextEditingController offsetController = TextEditingController(
      text: (textLength ~/ 2).clamp(1, textLength - 1).toString(),
    );
    final TextEditingController timeController = TextEditingController(
      text: ((segment.start + segment.end) / 2).toStringAsFixed(3),
    );

    try {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder:
            (BuildContext context) => AlertDialog(
              title: Text('拆分第 ${index + 1} 条字幕'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: offsetController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '左侧字数'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: timeController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '分割时间（秒）'),
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确认拆分'),
                ),
              ],
            ),
      );

      if (confirmed == true && mounted) {
        final int? offset = int.tryParse(offsetController.text.trim());
        final double? splitTime = double.tryParse(timeController.text.trim());
        if (offset != null && splitTime != null) {
          _cancelInlineEdit();
          widget.onSplitSegment?.call(
            index,
            characterOffset: offset,
            splitTime: splitTime,
          );
        }
      }
    } finally {
      offsetController.dispose();
      timeController.dispose();
    }
  }

  void _startInlineEdit(Segment segment, {required bool isTranslation}) {
    _editingController?.dispose();
    _editingController = TextEditingController(
      text: isTranslation ? (segment.translation ?? '') : segment.text,
    );
    setState(() {
      _editingIndex = segment.index;
      _editingTranslation = isTranslation;
    });
  }

  /// 合并、拆分或删除会重新编号字幕，不能让正在编辑的输入框继续绑定旧序号。
  void _cancelInlineEdit() {
    final TextEditingController? controller = _editingController;
    if (controller == null && _editingIndex == null) return;
    setState(() {
      _editingIndex = null;
      _editingTranslation = false;
      _editingController = null;
    });
    controller?.dispose();
  }

  void _finishInlineEdit(Segment segment, {required bool save}) {
    final TextEditingController? controller = _editingController;
    final String value = controller?.text.trim() ?? '';
    final bool isTranslation = _editingTranslation;
    setState(() {
      _editingIndex = null;
      _editingTranslation = false;
      _editingController = null;
    });
    controller?.dispose();
    if (!save) return;
    if (isTranslation) {
      widget.onUpdateTranslation?.call(segment.index, value);
    } else {
      widget.onUpdateSegment?.call(segment.index, text: value);
    }
  }

  Future<void> _showEditSpeakerDialog(int index) async {
    final Segment segment = widget.segments[index];
    final TextEditingController speakerController = TextEditingController(
      text: segment.speaker ?? '',
    );
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder:
          (BuildContext context) => AlertDialog(
            title: Text('设置第 ${index + 1} 条说话人'),
            content: TextField(
              controller: speakerController,
              decoration: const InputDecoration(
                labelText: '说话人标识 (如 Speaker 1)',
                hintText: '留空清除说话人',
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存'),
              ),
            ],
          ),
    );
    if (confirmed == true && mounted) {
      widget.onUpdateSegment?.call(
        index,
        speaker: speakerController.text.trim(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Segment> allSegments = widget.segments;
    final Set<String> speakers = <String>{
      for (final Segment s in allSegments)
        if ((s.speaker ?? '').trim().isNotEmpty) s.speaker!.trim(),
    };

    final List<Segment> filtered =
        allSegments.where((Segment s) {
          if (_selectedSpeakerFilter != null &&
              s.speaker != _selectedSpeakerFilter) {
            return false;
          }
          if (_searchQuery.isNotEmpty) {
            final bool matchesText = s.text.toLowerCase().contains(
              _searchQuery.toLowerCase(),
            );
            final bool matchesTrans = (s.translation ?? '')
                .toLowerCase()
                .contains(_searchQuery.toLowerCase());
            return matchesText || matchesTrans;
          }
          return true;
        }).toList();

    final Segment? currentActive = activeSegment(
      allSegments,
      widget.videoController.position,
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      child: Column(
        children: <Widget>[
          // 顶部检索与过滤栏
          _buildFilterBar(speakers, allSegments.length),
          const Divider(height: 1),
          // 字幕列表
          Expanded(
            child:
                filtered.isEmpty
                    ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.subtitles_off_outlined,
                            size: 36,
                            color: StudioColors.textMuted,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _searchQuery.isNotEmpty
                                ? '未找到包含 "$_searchQuery" 的字幕'
                                : '暂无字幕数据，请先转写或导入字幕',
                            style: const TextStyle(
                              color: StudioColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                    : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (BuildContext context, int i) {
                        final Segment segment = filtered[i];
                        final bool isActive =
                            currentActive?.index == segment.index;
                        final bool isEditingThis =
                            _editingIndex == segment.index;
                        return _buildSegmentCard(
                          context,
                          segment,
                          isActive: isActive,
                          isEditing: isEditingThis,
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(Set<String> speakers, int totalCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: StudioColors.surfaceSubtle,
      child: Row(
        children: <Widget>[
          // 搜索框
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: '搜索字幕内容或译文...',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  suffixIcon:
                      _searchQuery.isNotEmpty
                          ? IconButton(
                            icon: const Icon(Icons.clear, size: 14),
                            onPressed: () => _searchController.clear(),
                          )
                          : null,
                  contentPadding: EdgeInsets.zero,
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 说话人筛选
          if (speakers.isNotEmpty) ...<Widget>[
            DropdownButton<String?>(
              value: _selectedSpeakerFilter,
              hint: const Text('全部说话人', style: TextStyle(fontSize: 11)),
              underline: const SizedBox.shrink(),
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('全部说话人', style: TextStyle(fontSize: 11)),
                ),
                for (final String spk in speakers)
                  DropdownMenuItem<String?>(
                    value: spk,
                    child: Text(spk, style: const TextStyle(fontSize: 11)),
                  ),
              ],
              onChanged: (String? val) {
                setState(() => _selectedSpeakerFilter = val);
              },
            ),
            const SizedBox(width: 6),
          ],
          // 自动跟随滚动开关
          Tooltip(
            message: _autoScroll ? '自动跟随播放滚动: 开' : '自动跟随播放滚动: 关',
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => setState(() => _autoScroll = !_autoScroll),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      _autoScroll
                          ? Icons.vertical_align_center
                          : Icons.vertical_align_bottom,
                      size: 16,
                      color:
                          _autoScroll
                              ? StudioColors.primary
                              : StudioColors.textMuted,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '跟随',
                      style: TextStyle(
                        fontSize: 11,
                        color:
                            _autoScroll
                                ? StudioColors.primary
                                : StudioColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 统计
          Text(
            '共 $totalCount 句',
            style: const TextStyle(
              fontSize: 11,
              color: StudioColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentCard(
    BuildContext context,
    Segment segment, {
    required bool isActive,
    required bool isEditing,
  }) {
    final double duration = segment.end - segment.start;
    final String translation = (segment.translation ?? '').trim();
    final bool canRetryTranslation =
        widget.canRetryTranslation?.call(segment) ?? false;
    final bool retryingTranslation =
        widget.isRetryingTranslation?.call(segment) ?? false;
    final bool canSplit = segment.text.trim().length >= 2;
    final String timeSpan =
        '${formatTimestamp(segment.start, sep: '.')} → ${formatTimestamp(segment.end, sep: '.')} (${duration.toStringAsFixed(2)}s)';

    Color cardBorder = StudioColors.border;
    Color cardBg = Colors.white;

    if (isActive) {
      cardBorder = StudioColors.activeSegmentBorder;
      cardBg = StudioColors.activeSegmentBg;
    }

    return Card(
      key: ValueKey<int>(segment.index),
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: cardBorder,
          width: isActive ? 1.5 : 1.0,
        ),
      ),
      color: cardBg,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          // 点击卡片瞬间跳转播放器
          widget.onSeek?.call(
            Duration(
              microseconds:
                  (segment.start * Duration.microsecondsPerSecond).round(),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 卡片头部元数据与操作
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: <Widget>[
                  // 序号
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color:
                          isActive
                              ? StudioColors.primary
                              : StudioColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '#${(segment.index + 1).toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color:
                            isActive
                                ? Colors.white
                                : StudioColors.textSecondary,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  // 时间轴范围
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        timeSpan,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: StudioColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  if ((segment.speaker ?? '').trim().isNotEmpty)
                    InkWell(
                      onTap: () => _showEditSpeakerDialog(segment.index),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: StudioColors.primarySubtle,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          segment.speaker!.trim(),
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: StudioColors.primary,
                          ),
                        ),
                      ),
                    ),
                  // 快捷操作工具
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        tooltip: '试听本句',
                        icon: const Icon(Icons.play_arrow, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        onPressed: () {
                          widget.onSeek?.call(
                            Duration(
                              microseconds:
                                  (segment.start * Duration.microsecondsPerSecond)
                                      .round(),
                            ),
                          );
                          widget.videoController.playOrPause();
                        },
                      ),
                      IconButton(
                        tooltip: '拆分此句',
                        icon: const Icon(Icons.call_split, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        onPressed: canSplit
                            ? () => _showSplitDialog(segment.index)
                            : null,
                      ),
                      if (segment.index + 1 < widget.segments.length)
                        IconButton(
                          tooltip: '与下一句合并',
                          icon: const Icon(Icons.merge, size: 16),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 24,
                            minHeight: 24,
                          ),
                          onPressed:
                              () {
                                _cancelInlineEdit();
                                widget.onMergeSegments?.call(segment.index);
                              },
                        ),
                      if (widget.segments.length > 1)
                        IconButton(
                          tooltip: '删除此句',
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 16,
                            color: StudioColors.error,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 24,
                            minHeight: 24,
                          ),
                          onPressed:
                              () {
                                _cancelInlineEdit();
                                widget.onDeleteSegment?.call(segment.index);
                              },
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // 原文字幕 (就地编辑)
              isEditing && !_editingTranslation
                  ? _buildInlineEditor(segment, isTranslation: false)
                  : InkWell(
                    onDoubleTap: () {
                      _startInlineEdit(segment, isTranslation: false);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        segment.text,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: StudioColors.textPrimary,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
              // 译文字幕 (如果有或正在编辑)
              if (translation.isNotEmpty ||
                  (isEditing && _editingTranslation) ||
                  canRetryTranslation) ...<Widget>[
                const SizedBox(height: 4),
                isEditing && _editingTranslation
                    ? _buildInlineEditor(segment, isTranslation: true)
                    : InkWell(
                      onDoubleTap: () {
                        _startInlineEdit(segment, isTranslation: true);
                      },
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              translation.isEmpty
                                  ? '暂无译文（双击可手动填写）'
                                  : translation,
                              style: TextStyle(
                                fontSize: 12,
                                color: translation.isEmpty
                                    ? StudioColors.textMuted
                                    : StudioColors.primary,
                                height: 1.35,
                              ),
                            ),
                          ),
                          if (canRetryTranslation)
                            IconButton(
                              key: ValueKey<String>(
                                'retryTranslation_${segment.index}',
                              ),
                              tooltip: '重新翻译本句',
                              icon:
                                  retryingTranslation
                                      ? const SizedBox.square(
                                        dimension: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                      : const Icon(
                                        Icons.refresh,
                                        size: 14,
                                        color: StudioColors.primary,
                                      ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 20,
                                minHeight: 20,
                              ),
                              onPressed: retryingTranslation
                                  ? null
                                  : () => widget.onRetryTranslation?.call(
                                      segment,
                                    ),
                            ),
                        ],
                      ),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInlineEditor(Segment segment, {required bool isTranslation}) {
    final TextEditingController? textController = _editingController;
    if (textController == null) return const SizedBox.shrink();

    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: textController,
            autofocus: true,
            style: TextStyle(
              fontSize: isTranslation ? 12 : 13,
              color:
                  isTranslation
                      ? StudioColors.primary
                      : StudioColors.textPrimary,
            ),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: StudioColors.primary),
              ),
            ),
            onSubmitted: (String val) {
              _finishInlineEdit(segment, save: true);
            },
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '保存',
          icon: const Icon(Icons.check, size: 16, color: StudioColors.success),
          onPressed: () {
            _finishInlineEdit(segment, save: true);
          },
        ),
        IconButton(
          tooltip: '取消',
          icon: const Icon(Icons.close, size: 16, color: StudioColors.textMuted),
          onPressed: () => _finishInlineEdit(segment, save: false),
        ),
      ],
    );
  }
}
