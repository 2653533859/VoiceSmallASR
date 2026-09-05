/// Studio 专业视频监视器与控制组件。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/subtitles/subtitle_style.dart';
import 'package:vsasr_app/src/ui/theme/studio_theme.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_player_widgets.dart';
import 'package:vsasr_app/src/video/video_timeline.dart';

extension on VideoSubtitleDisplayMode {
  String get label => switch (this) {
    VideoSubtitleDisplayMode.off => '关闭',
    VideoSubtitleDisplayMode.original => '原文',
    VideoSubtitleDisplayMode.translation => '译文',
    VideoSubtitleDisplayMode.bilingual => '双语',
  };
}

class StudioVideoMonitor extends StatefulWidget {
  const StudioVideoMonitor({
    super.key,
    required this.controller,
    required this.segments,
    this.subtitleStyle = const SubtitleStyle(),
    this.displayMode = VideoSubtitleDisplayMode.bilingual,
    this.onDisplayModeChanged,
    this.onOpenMedia,
    this.onSegmentSelected,
    this.currentLoopSegment,
    this.onToggleLoop,
  });

  final VideoPlaybackController controller;
  final List<Segment> segments;
  final SubtitleStyle subtitleStyle;
  final VideoSubtitleDisplayMode displayMode;
  final ValueChanged<VideoSubtitleDisplayMode>? onDisplayModeChanged;
  final VoidCallback? onOpenMedia;
  final ValueChanged<Segment>? onSegmentSelected;
  final Segment? currentLoopSegment;
  final ValueChanged<bool>? onToggleLoop;

  @override
  State<StudioVideoMonitor> createState() => _StudioVideoMonitorState();
}

class _StudioVideoMonitorState extends State<StudioVideoMonitor> {
  bool _looping = false;
  Segment? _lastLoopSegment;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPlaybackUpdate);
  }

  @override
  void didUpdateWidget(StudioVideoMonitor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPlaybackUpdate);
      widget.controller.addListener(_onPlaybackUpdate);
    }
    if (widget.currentLoopSegment != null) {
      _lastLoopSegment = widget.currentLoopSegment;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPlaybackUpdate);
    super.dispose();
  }

  void _onPlaybackUpdate() {
    if (!mounted) return;
    if (_looping && _lastLoopSegment != null) {
      final double currentSec =
          widget.controller.position.inMicroseconds /
          Duration.microsecondsPerSecond;
      if (currentSec >= _lastLoopSegment!.end) {
        unawaited(
          widget.controller.seek(
            Duration(
              microseconds:
                  (_lastLoopSegment!.start * Duration.microsecondsPerSecond)
                      .round(),
            ),
          ),
        );
      }
    }
    setState(() {});
  }

  void _seekBy(int seconds) {
    final VideoPlaybackController c = widget.controller;
    if (c.filePath == null || c.busy) return;
    final Duration target = c.position + Duration(seconds: seconds);
    unawaited(c.seek(target));
  }

  String _formatPrecise(Duration duration) {
    final int totalHundredths = duration.inMilliseconds ~/ 10;
    final int hundredths = totalHundredths % 100;
    final int totalSeconds = duration.inSeconds;
    final int seconds = totalSeconds % 60;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int hours = totalSeconds ~/ 3600;

    final String secStr = seconds.toString().padLeft(2, '0');
    final String minStr = minutes.toString().padLeft(2, '0');
    final String hStr = hundredths.toString().padLeft(2, '0');

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minStr:$secStr.$hStr';
    }
    return '$minStr:$secStr.$hStr';
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlaybackController c = widget.controller;
    final Segment? active = activeSegment(widget.segments, c.position);
    if (active != null) {
      _lastLoopSegment = active;
    }

    final String subtitleText =
        active == null
            ? ''
            : subtitleTextForSegment(active, widget.displayMode);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: StudioColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 视频主体监视窗
          Expanded(
            child: Container(
              color: Colors.black,
              child:
                  c.filePath == null
                      ? Center(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 16,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: const BoxDecoration(
                                    color: Colors.white10,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.video_library_outlined,
                                    size: 32,
                                    color: Colors.white70,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '选一个音频或视频文件开始',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  '支持 MP4, MKV, MP3, WAV 等格式，享受双栏音画联动剪辑',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                                if (widget.onOpenMedia != null) ...<Widget>[
                                  const SizedBox(height: 14),
                                  FilledButton.icon(
                                    onPressed: widget.onOpenMedia,
                                    icon: const Icon(Icons.folder_open, size: 15),
                                    label: const Text('打开媒体文件'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: StudioColors.primary,
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 8,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      )
                      : Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          c.buildVideo(),
                          // 屏幕字幕实时 Overlay
                          if (subtitleText.isNotEmpty)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Align(
                                  alignment:
                                      widget.subtitleStyle.position.alignment,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 16,
                                    ),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: widget.subtitleStyle.background,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        child: Builder(
                                          builder: (BuildContext context) {
                                            final Widget text = RichText(
                                              key: const Key(
                                                'videoOverlaySubtitleText',
                                              ),
                                              textAlign: TextAlign.center,
                                              text: TextSpan(
                                                text: subtitleText,
                                                style: TextStyle(
                                                  color:
                                                      widget
                                                          .subtitleStyle
                                                          .foreground,
                                                  fontSize:
                                                      widget
                                                          .subtitleStyle
                                                          .fontSize,
                                                  height: 1.35,
                                                ),
                                              ),
                                            );
                                            return Platform.isMacOS
                                                ? ExcludeSemantics(child: text)
                                                : text;
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (c.busy)
                            const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                              ),
                            ),
                        ],
                      ),
            ),
          ),
          // 专业控制条
          _buildControlBar(context, c),
        ],
      ),
    );
  }

  Widget _buildControlBar(BuildContext context, VideoPlaybackController c) {
    final double totalSec =
        c.duration.inMicroseconds / Duration.microsecondsPerSecond;
    final double currentSec =
        c.position.inMicroseconds / Duration.microsecondsPerSecond;
    final double maxSec = totalSec > 0 ? totalSec : 1.0;
    final double clampedSec = currentSec.clamp(0.0, maxSec);

    return Container(
      color: StudioColors.surfaceElevated,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 时间轴进度条
          Row(
            children: <Widget>[
              Text(
                _formatPrecise(c.position),
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                  color: StudioColors.textPrimary,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    activeTrackColor: StudioColors.primary,
                    inactiveTrackColor: StudioColors.timelineTrack,
                    thumbColor: StudioColors.primary,
                  ),
                  child: Slider(
                    value: clampedSec,
                    min: 0.0,
                    max: maxSec,
                    onChanged:
                        c.filePath == null || c.busy
                            ? null
                            : (double sec) {
                              unawaited(
                                c.seek(
                                  Duration(
                                    microseconds:
                                        (sec * Duration.microsecondsPerSecond)
                                            .round(),
                                  ),
                                ),
                              );
                            },
                  ),
                ),
              ),
              Text(
                _formatPrecise(c.duration),
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: StudioColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // 快捷控制按键与胶囊
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                // 播放/暂停
                IconButton(
                  tooltip: c.playing ? '暂停 (Space)' : '播放 (Space)',
                  icon: Icon(
                    c.playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                    size: 28,
                    color: StudioColors.primary,
                  ),
                  onPressed:
                      c.filePath == null || c.busy ? null : c.playOrPause,
                ),
                const SizedBox(width: 4),
                // 快退 2s
                IconButton(
                  tooltip: '快退 2 秒',
                  icon: const Icon(Icons.replay_10, size: 20),
                  onPressed:
                      c.filePath == null || c.busy ? null : () => _seekBy(-2),
                ),
                // 快进 2s
                IconButton(
                  tooltip: '快进 2 秒',
                  icon: const Icon(Icons.forward_10, size: 20),
                  onPressed:
                      c.filePath == null || c.busy ? null : () => _seekBy(2),
                ),
                const SizedBox(width: 8),
                // 单句循环 (A-B Loop)
                FilterChip(
                  label: const Text('循环本句', style: TextStyle(fontSize: 11)),
                  avatar: Icon(
                    Icons.repeat_one,
                    size: 14,
                    color:
                        _looping
                            ? StudioColors.primary
                            : StudioColors.textSecondary,
                  ),
                  selected: _looping,
                  onSelected:
                      c.filePath == null
                          ? null
                          : (bool value) {
                            setState(() => _looping = value);
                            widget.onToggleLoop?.call(value);
                          },
                  backgroundColor: Colors.white,
                  selectedColor: StudioColors.primarySubtle,
                  checkmarkColor: StudioColors.primary,
                  side: BorderSide(
                    color:
                        _looping ? StudioColors.primary : StudioColors.border,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 12),
                // 字幕显示模式切换
                PopupMenuButton<VideoSubtitleDisplayMode>(
                  key: const Key('videoSubtitleMode'),
                  tooltip: '字幕预览：${widget.displayMode.label}',
                  initialValue: widget.displayMode,
                  onSelected: widget.onDisplayModeChanged,
                  itemBuilder:
                      (BuildContext context) =>
                          <PopupMenuEntry<VideoSubtitleDisplayMode>>[
                            for (final VideoSubtitleDisplayMode mode
                                in VideoSubtitleDisplayMode.values)
                              CheckedPopupMenuItem<VideoSubtitleDisplayMode>(
                                key: Key('videoSubtitleMode-${mode.name}'),
                                value: mode,
                                checked: mode == widget.displayMode,
                                child: Text(mode.label),
                              ),
                          ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.closed_caption_outlined, size: 16),
                        const SizedBox(width: 4),
                        Text(
                          '字幕：${widget.displayMode.label}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        const Icon(Icons.arrow_drop_down, size: 16),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // 倍速切换
                PopupMenuButton<double>(
                  key: const Key('videoPlaybackRate'),
                  tooltip: '倍速：${c.rate}x',
                  initialValue: c.rate,
                  onSelected: (double rate) => unawaited(c.setRate(rate)),
                  itemBuilder:
                      (BuildContext context) => <PopupMenuEntry<double>>[
                        for (final double rate in const <double>[
                          0.5,
                          0.75,
                          1.0,
                          1.25,
                          1.5,
                          2.0,
                        ])
                          PopupMenuItem<double>(
                            key: Key('videoPlaybackRate-$rate'),
                            value: rate,
                            child: Text('${rate}x'),
                          ),
                      ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.speed, size: 16),
                        const SizedBox(width: 4),
                        Text(
                          '${c.rate}x',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down, size: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
