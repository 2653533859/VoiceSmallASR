/// 视频播放器及字幕显示相关的纯 UI 组件。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/subtitles/subtitle_style.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_timeline.dart';

extension on VideoSubtitleDisplayMode {
  String get label => switch (this) {
    VideoSubtitleDisplayMode.off => '关闭',
    VideoSubtitleDisplayMode.original => '原文',
    VideoSubtitleDisplayMode.translation => '译文',
    VideoSubtitleDisplayMode.bilingual => '双语',
  };
}

class VideoSurface extends StatelessWidget {
  const VideoSurface({
    super.key,
    required this.controller,
    required this.current,
    required this.style,
    required this.displayMode,
    required this.controls,
  });

  final VideoPlaybackController controller;
  final Segment? current;
  final SubtitleStyle style;
  final VideoSubtitleDisplayMode displayMode;
  final Widget? controls;

  @override
  Widget build(BuildContext context) {
    final String subtitleText = current == null
        ? ''
        : subtitleTextForSegment(current!, displayMode);
    final Widget? subtitle = subtitleText.isEmpty
        ? null
        : Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: style.position.alignment,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    20,
                    16,
                    style.position == SubtitlePosition.bottom &&
                            controls != null
                        ? 92
                        : 20,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: style.background,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Builder(
                        builder: (BuildContext context) {
                          final Widget text = Text(
                            subtitleText,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: style.foreground,
                              fontSize: style.fontSize,
                              height: 1.35,
                            ),
                          );
                          // Flutter macOS 的 AccessibilityBridge 在高频替换
                          // 字幕语义节点时可能崩溃。只排除动态字幕文本，保留
                          // 播放按钮、时间轴、菜单等控件的辅助功能语义。
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
          );

    return ColoredBox(
      color: Colors.black,
      child: controller.filePath == null
          ? const Center(
              child: Text('打开视频开始播放', style: TextStyle(color: Colors.white70)),
            )
          : controller.buildVideo(
              overlayBuilder: (Future<void> Function() toggleFullscreen) =>
                  Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ?subtitle,
                      if (controls != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Colors.transparent,
                                  Color(0xD9000000),
                                ],
                              ),
                            ),
                            child: Theme(
                              data: ThemeData.dark(useMaterial3: true),
                              child: VideoPlaybackControlsScope(
                                toggleFullscreen: toggleFullscreen,
                                child: controls!,
                              ),
                            ),
                          ),
                        ),
                      if (controller.busy)
                        const Center(child: CircularProgressIndicator()),
                    ],
                  ),
            ),
    );
  }
}

class VideoPlaybackControlsScope extends InheritedWidget {
  const VideoPlaybackControlsScope({
    super.key,
    required this.toggleFullscreen,
    required super.child,
  });

  final Future<void> Function() toggleFullscreen;

  static Future<void> Function() of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<VideoPlaybackControlsScope>()!
      .toggleFullscreen;

  @override
  bool updateShouldNotify(VideoPlaybackControlsScope oldWidget) => false;
}

class VideoPlaybackControls extends StatelessWidget {
  const VideoPlaybackControls({
    super.key,
    required this.controller,
    required this.hasSubtitles,
    required this.subtitleDisplayMode,
    required this.onSubtitleDisplayModeChanged,
    this.onPrevious,
    this.onNext,
  });

  final VideoPlaybackController controller;
  final bool hasSubtitles;
  final VideoSubtitleDisplayMode subtitleDisplayMode;
  final ValueChanged<VideoSubtitleDisplayMode> onSubtitleDisplayModeChanged;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final Future<void> Function() toggleFullscreen =
        VideoPlaybackControlsScope.of(context);
    final double total =
        controller.duration.inMicroseconds / Duration.microsecondsPerSecond;
    final double current =
        controller.position.inMicroseconds / Duration.microsecondsPerSecond;
    final double max = total > 0 ? total : 1;
    final Widget subtitleMenu = PopupMenuButton<VideoSubtitleDisplayMode>(
      key: const Key('videoSubtitleMode'),
      enabled: hasSubtitles,
      initialValue: subtitleDisplayMode,
      tooltip: '选择字幕显示内容',
      onSelected: onSubtitleDisplayModeChanged,
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<VideoSubtitleDisplayMode>>[
            for (final VideoSubtitleDisplayMode mode
                in VideoSubtitleDisplayMode.values)
              PopupMenuItem<VideoSubtitleDisplayMode>(
                key: Key('videoSubtitleMode-${mode.name}'),
                value: mode,
                child: Text(mode.label),
              ),
          ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.closed_caption_outlined, size: 20),
            const SizedBox(width: 4),
            Text('字幕：${subtitleDisplayMode.label}'),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
    final Widget rateMenu = PopupMenuButton<double>(
      key: const Key('videoPlaybackRate'),
      initialValue: controller.rate,
      tooltip: '调整播放倍速',
      onSelected: (double rate) => unawaited(controller.setRate(rate)),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<double>>[
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.speed, size: 20),
            const SizedBox(width: 4),
            Text('${controller.rate}x'),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
    Widget timeline() => Expanded(
      child: Slider(
        value: current.clamp(0.0, max),
        max: max,
        onChanged: total <= 0 || controller.busy
            ? null
            : (double value) => unawaited(
                controller.seek(
                  Duration(
                    microseconds: (value * Duration.microsecondsPerSecond)
                        .round(),
                  ),
                ),
              ),
      ),
    );
    final Widget previous = IconButton(
      tooltip: '上一个视频',
      onPressed: controller.busy ? null : onPrevious,
      icon: const Icon(Icons.skip_previous),
    );
    final Widget play = IconButton(
      tooltip: controller.playing ? '暂停' : '播放',
      onPressed: controller.busy
          ? null
          : () => unawaited(controller.playOrPause()),
      icon: Icon(controller.playing ? Icons.pause : Icons.play_arrow),
    );
    final Widget next = IconButton(
      tooltip: '下一个视频',
      onPressed: controller.busy ? null : onNext,
      icon: const Icon(Icons.skip_next),
    );
    final Widget position = Text(
      '${formatVideoDuration(controller.position)} / '
      '${formatVideoDuration(controller.duration)}',
    );
    final Widget fullscreen = IconButton(
      tooltip: '切换全屏',
      onPressed: () => unawaited(toggleFullscreen()),
      icon: const Icon(Icons.fullscreen),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    previous,
                    play,
                    position,
                    timeline(),
                    next,
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[subtitleMenu, rateMenu, fullscreen],
                  ),
                ),
              ],
            );
          }
          return Row(
            children: <Widget>[
              previous,
              play,
              position,
              const SizedBox(width: 8),
              subtitleMenu,
              rateMenu,
              timeline(),
              next,
              fullscreen,
            ],
          );
        },
      ),
    );
  }
}

class VideoSubtitleList extends StatelessWidget {
  const VideoSubtitleList({
    super.key,
    required this.controller,
    required this.result,
    required this.displayMode,
  });

  final VideoPlaybackController controller;
  final TranscriptionResult result;
  final VideoSubtitleDisplayMode displayMode;

  @override
  Widget build(BuildContext context) {
    final Segment? current = activeSegment(
      result.segments,
      controller.position,
    );
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: result.segments.length,
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final Segment segment = result.segments[index];
        final String translation = (segment.translation ?? '').trim();
        final bool showOriginal =
            displayMode == VideoSubtitleDisplayMode.original ||
            displayMode == VideoSubtitleDisplayMode.bilingual;
        final bool showTranslation =
            displayMode == VideoSubtitleDisplayMode.translation ||
            displayMode == VideoSubtitleDisplayMode.bilingual;
        final bool selected =
            identical(segment, current) ||
            (current != null &&
                segment.index == current.index &&
                segment.start == current.start);
        return ListTile(
          dense: true,
          selected: selected,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (showOriginal && (segment.speaker ?? '').trim().isNotEmpty)
                Text(
                  '【${segment.speaker!.trim()}】',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              if (showOriginal) Text(segment.text),
              if (showTranslation && translation.isNotEmpty)
                Text(
                  translation,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                )
              else if (showTranslation && !showOriginal)
                Text(
                  '暂无译文',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
            ],
          ),
          subtitle: Text(
            '${formatVideoDuration(Duration(milliseconds: (segment.start * 1000).round()))} → '
            '${formatVideoDuration(Duration(milliseconds: (segment.end * 1000).round()))}',
          ),
          onTap: () => unawaited(
            controller.seek(
              Duration(
                microseconds: (segment.start * Duration.microsecondsPerSecond)
                    .round(),
              ),
            ),
          ),
        );
      },
    );
  }
}

String formatVideoDuration(Duration duration) {
  final int totalSeconds = duration.inSeconds;
  final String hours = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
  final String minutes = ((totalSeconds % 3600) ~/ 60).toString().padLeft(
    2,
    '0',
  );
  final String seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return totalSeconds >= 3600
      ? '$hours:$minutes:$seconds'
      : '$minutes:$seconds';
}

String subtitleTextForSegment(Segment segment, VideoSubtitleDisplayMode mode) {
  final String translation = (segment.translation ?? '').trim();
  return switch (mode) {
    VideoSubtitleDisplayMode.off => '',
    VideoSubtitleDisplayMode.original => <String>[
      if ((segment.speaker ?? '').trim().isNotEmpty)
        '【${segment.speaker!.trim()}】',
      segment.text,
    ].join('\n'),
    VideoSubtitleDisplayMode.translation => translation,
    VideoSubtitleDisplayMode.bilingual => <String>[
      if ((segment.speaker ?? '').trim().isNotEmpty)
        '【${segment.speaker!.trim()}】',
      segment.text,
      if (translation.isNotEmpty) translation,
    ].join('\n'),
  };
}
