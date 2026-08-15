/// 视频播放、字幕叠加与时间轴联动页面。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_timeline.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

/// 选择视频文件，取消时返回 null。
typedef PickVideoFile = Future<String?> Function();

class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.controller,
    required this.transcription,
    this.pickFile,
  });

  final VideoPlaybackController controller;
  final TranscribeController transcription;
  final PickVideoFile? pickFile;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  Future<String?> _pickFile() async {
    final PickVideoFile? injected = widget.pickFile;
    if (injected != null) return injected();
    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: '选择视频',
      type: FileType.custom,
      allowedExtensions: kVideoExtensions,
    );
    return picked?.path;
  }

  Future<void> _openVideo() async {
    final String? path = await _pickFile();
    if (path == null) return;
    await widget.controller.open(path);
  }

  Future<void> _openTranscribedVideo() async {
    final String? path = widget.transcription.filePath;
    if (path == null) return;
    await widget.controller.open(path);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[widget.controller, widget.transcription]),
      builder: (BuildContext context, Widget? _) {
        final VideoPlaybackController video = widget.controller;
        final TranscriptionResult? result = widget.transcription.result;
        final bool hasLinkedResult =
            result != null && video.filePath != null && video.filePath == widget.transcription.filePath;
        final Segment? current = hasLinkedResult ? activeSegment(result.segments, video.position) : null;
        final String? transcribedPath = widget.transcription.filePath;
        final String transcribedExtension =
            transcribedPath == null ? '' : p.extension(transcribedPath).replaceFirst('.', '').toLowerCase();
        final bool transcribedVideo =
            transcribedPath != null && kVideoExtensions.contains(transcribedExtension);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: video.busy ? null : _openVideo,
                    icon: const Icon(Icons.video_library_outlined),
                    label: const Text('打开视频'),
                  ),
                  if (transcribedVideo) ...<Widget>[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: video.busy ? null : _openTranscribedVideo,
                      icon: const Icon(Icons.subtitles_outlined),
                      label: const Text('加载已转写视频'),
                    ),
                  ],
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      video.filePath == null ? '尚未打开视频' : p.basename(video.filePath!),
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: hasLinkedResult ? 3 : 4,
              child: _VideoSurface(controller: video, current: current),
            ),
            if (video.filePath != null) _PlaybackControls(controller: video),
            if (video.errorText != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(
                  video.errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (hasLinkedResult)
              Expanded(
                flex: 2,
                child: _SubtitleList(controller: video, result: result),
              )
            else if (video.filePath == null)
              const Expanded(child: Center(child: Text('打开视频，或先在「文件转写」页签识别一个视频'))),
          ],
        );
      },
    );
  }
}

class _VideoSurface extends StatelessWidget {
  const _VideoSurface({required this.controller, required this.current});

  final VideoPlaybackController controller;
  final Segment? current;

  @override
  Widget build(BuildContext context) {
    final Widget? subtitle = current == null
        ? null
        : Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    <String>[current!.text, if ((current!.translation ?? '').trim().isNotEmpty) current!.translation!]
                        .join('\n'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 18, height: 1.35),
                  ),
                ),
              ),
            ),
          );

    return ColoredBox(
      color: Colors.black,
      child: controller.filePath == null
          ? const Center(child: Text('打开视频开始播放', style: TextStyle(color: Colors.white70)))
          : Stack(
              fit: StackFit.expand,
              children: <Widget>[
                controller.buildVideo(),
                ?subtitle,
                if (controller.busy) const Center(child: CircularProgressIndicator()),
              ],
            ),
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({required this.controller});

  final VideoPlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final double total = controller.duration.inMicroseconds / Duration.microsecondsPerSecond;
    final double current = controller.position.inMicroseconds / Duration.microsecondsPerSecond;
    final double max = total > 0 ? total : 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: controller.playing ? '暂停' : '播放',
            onPressed: controller.busy ? null : () => unawaited(controller.playOrPause()),
            icon: Icon(controller.playing ? Icons.pause : Icons.play_arrow),
          ),
          Text('${_formatDuration(controller.position)} / ${_formatDuration(controller.duration)}'),
          Expanded(
            child: Slider(
              value: current.clamp(0.0, max),
              max: max,
              onChanged: total <= 0 || controller.busy
                  ? null
                  : (double value) => unawaited(
                        controller.seek(
                          Duration(microseconds: (value * Duration.microsecondsPerSecond).round()),
                        ),
                      ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubtitleList extends StatelessWidget {
  const _SubtitleList({required this.controller, required this.result});

  final VideoPlaybackController controller;
  final TranscriptionResult result;

  @override
  Widget build(BuildContext context) {
    final Segment? current = activeSegment(result.segments, controller.position);
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: result.segments.length,
      separatorBuilder: (BuildContext context, int index) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final Segment segment = result.segments[index];
        final bool selected = identical(segment, current) ||
            (current != null && segment.index == current.index && segment.start == current.start);
        return ListTile(
          dense: true,
          selected: selected,
          title: Text(segment.text),
          subtitle: Text(
            '${_formatDuration(Duration(milliseconds: (segment.start * 1000).round()))} → '
            '${_formatDuration(Duration(milliseconds: (segment.end * 1000).round()))}',
          ),
          onTap: () => unawaited(
            controller.seek(Duration(microseconds: (segment.start * Duration.microsecondsPerSecond).round())),
          ),
        );
      },
    );
  }
}

String _formatDuration(Duration duration) {
  final int totalSeconds = duration.inSeconds;
  final String hours = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
  final String minutes = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
  final String seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return totalSeconds >= 3600 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
