/// 视频播放、字幕叠加与时间轴联动页面。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/translation/translation_disclosure.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_timeline.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_page.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

/// 选择视频文件，取消时返回 null。
typedef PickVideoFile = Future<String?> Function();

class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.controller,
    required this.transcription,
    this.pickFile,
    this.pickSubtitleFile,
    this.settings,
    this.translationProviderResolver,
  });

  final VideoPlaybackController controller;
  final TranscribeController transcription;
  final PickVideoFile? pickFile;
  final PickSubtitleFile? pickSubtitleFile;
  final AppSettingsRepository? settings;
  final Future<TranslationProvider?> Function()? translationProviderResolver;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  bool _translationDisclosureAccepted = false;
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

  Future<SubtitleFileData?> _pickSubtitleFile() async {
    final PickSubtitleFile? injected = widget.pickSubtitleFile;
    if (injected != null) return injected();
    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: '加载外部字幕',
      type: FileType.custom,
      allowedExtensions: kSubtitleImportFormats,
    );
    if (picked == null) return null;
    final String? path = picked.path;
    return SubtitleFileData(
      name: picked.name,
      path: path,
      bytes: path == null ? await picked.readAsBytes() : null,
    );
  }

  Future<String> _readSubtitleFile(SubtitleFileData selected) async {
    final Uint8List? bytes = selected.bytes;
    if (bytes != null) return utf8.decode(bytes);
    final String? path = selected.path;
    if (path == null) throw const FormatException('字幕文件没有可读取的路径');
    return File(path).readAsString();
  }

  String _subtitleFormat(SubtitleFileData selected) {
    final String source = selected.name.isNotEmpty
        ? selected.name
        : (selected.path ?? '');
    return p.extension(source).replaceFirst('.', '').toLowerCase();
  }

  Future<void> _importSubtitle() async {
    final String? mediaPath = widget.controller.filePath;
    if (mediaPath == null || widget.transcription.busy) return;
    final SubtitleFileData? selected = await _pickSubtitleFile();
    if (selected == null) return;
    try {
      final TranscriptionResult result = parseSubtitleText(
        await _readSubtitleFile(selected),
        format: _subtitleFormat(selected),
      );
      widget.transcription.applyImportedResult(result, mediaPath: mediaPath);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已加载字幕：${selected.name}')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载字幕失败：$error')));
    }
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

  Future<void> _translate() async {
    final TranscriptionResult? result = widget.transcription.result;
    if (result == null || widget.transcription.busy) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final Future<TranslationProvider?> Function()? resolver =
          widget.translationProviderResolver;
      final AppSettingsRepository? configuredRepository = widget.settings;
      final TranslationApiSettings settings = configuredRepository == null
          ? const TranslationApiSettings()
          : await configuredRepository.loadTranslationApiSettings();
      final TranslationProvider? provider = resolver == null
          ? await _loadTranslationProvider(
              configuredRepository ?? AppSettingsRepository(),
              settings,
            )
          : await resolver();
      try {
        if (!mounted) return;
        if (provider == null) {
          messenger.showSnackBar(
            const SnackBar(content: Text('请先在设置中保存第三方翻译 API Key')),
          );
          return;
        }
        if (!_translationDisclosureAccepted) {
          final bool confirmed = await confirmThirdPartyTranslation(context);
          if (!confirmed || !mounted) return;
          _translationDisclosureAccepted = true;
        }
        await widget.transcription.translateCurrentResult(
          provider,
          targetLanguage: settings.targetLanguage,
        );
      } finally {
        if (provider is ClosableTranslationProvider) provider.close();
      }
    } on Object catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('翻译失败：$error')));
    }
  }

  Future<TranslationProvider?> _loadTranslationProvider(
    AppSettingsRepository repository,
    TranslationApiSettings settings,
  ) async {
    final String? apiKey = await repository.translationSecrets.readApiKey();
    if (apiKey == null) return null;
    return ApiTranslationProvider(
      apiKey: apiKey,
      endpoint: settings.endpoint,
      model: settings.model,
    );
  }

  Future<void> _openEditor(TranscriptionResult result) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SubtitleEditorPage(
          initialResult: result,
          player: widget.controller,
          onSave: widget.transcription.applyEditedResult,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.controller,
        widget.transcription,
      ]),
      builder: (BuildContext context, Widget? _) {
        final VideoPlaybackController video = widget.controller;
        final TranscriptionResult? result = widget.transcription.result;
        final bool hasLinkedResult =
            result != null &&
            video.filePath != null &&
            video.filePath == widget.transcription.filePath;
        final Segment? current = hasLinkedResult
            ? activeSegment(result.segments, video.position)
            : null;
        final String? transcribedPath = widget.transcription.filePath;
        final String transcribedExtension = transcribedPath == null
            ? ''
            : p.extension(transcribedPath).replaceFirst('.', '').toLowerCase();
        final bool transcribedVideo =
            transcribedPath != null &&
            kVideoExtensions.contains(transcribedExtension);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: video.busy ? null : _openVideo,
                    icon: const Icon(Icons.video_library_outlined),
                    label: const Text('打开视频'),
                  ),
                  if (transcribedVideo) ...<Widget>[
                    OutlinedButton.icon(
                      onPressed: video.busy ? null : _openTranscribedVideo,
                      icon: const Icon(Icons.subtitles_outlined),
                      label: const Text('加载已转写视频'),
                    ),
                  ],
                  if (video.filePath != null)
                    OutlinedButton.icon(
                      key: const Key('videoImportSubtitle'),
                      onPressed: video.busy || widget.transcription.busy
                          ? null
                          : _importSubtitle,
                      icon: const Icon(Icons.subtitles_outlined),
                      label: const Text('加载外部字幕'),
                    ),
                  if (hasLinkedResult) ...<Widget>[
                    OutlinedButton.icon(
                      key: const Key('videoSubtitleEditor'),
                      onPressed: video.busy ? null : () => _openEditor(result),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('编辑字幕'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('videoTranslateSubtitle'),
                      onPressed: video.busy || widget.transcription.busy
                          ? null
                          : _translate,
                      icon: const Icon(Icons.translate),
                      label: const Text('翻译字幕'),
                    ),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: Text(
                      video.filePath == null
                          ? '尚未打开视频'
                          : p.basename(video.filePath!),
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            if (widget.transcription.stage == JobStage.translating) ...<Widget>[
              LinearProgressIndicator(value: widget.transcription.progress),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(widget.transcription.statusText),
              ),
            ],
            Expanded(
              flex: hasLinkedResult ? 3 : 4,
              child: _VideoSurface(controller: video, current: current),
            ),
            if (video.filePath != null) _PlaybackControls(controller: video),
            if (video.errorText != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
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
              const Expanded(
                child: Center(child: Text('打开视频，或先在「文件转写」页签识别一个视频')),
              ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    <String>[
                      current!.text,
                      if ((current!.translation ?? '').trim().isNotEmpty)
                        current!.translation!,
                    ].join('\n'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      height: 1.35,
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
          : Stack(
              fit: StackFit.expand,
              children: <Widget>[
                controller.buildVideo(),
                ?subtitle,
                if (controller.busy)
                  const Center(child: CircularProgressIndicator()),
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
    final double total =
        controller.duration.inMicroseconds / Duration.microsecondsPerSecond;
    final double current =
        controller.position.inMicroseconds / Duration.microsecondsPerSecond;
    final double max = total > 0 ? total : 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: controller.playing ? '暂停' : '播放',
            onPressed: controller.busy
                ? null
                : () => unawaited(controller.playOrPause()),
            icon: Icon(controller.playing ? Icons.pause : Icons.play_arrow),
          ),
          Text(
            '${_formatDuration(controller.position)} / ${_formatDuration(controller.duration)}',
          ),
          Expanded(
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
              Text(segment.text),
              if ((segment.translation ?? '').trim().isNotEmpty)
                Text(
                  segment.translation!.trim(),
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
            ],
          ),
          subtitle: Text(
            '${_formatDuration(Duration(milliseconds: (segment.start * 1000).round()))} → '
            '${_formatDuration(Duration(milliseconds: (segment.end * 1000).round()))}',
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

String _formatDuration(Duration duration) {
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
