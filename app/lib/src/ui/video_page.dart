/// 视频播放、字幕叠加与时间轴联动页面。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/audio/media_file_order.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/subtitles/subtitle_style.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/translation/translation_disclosure.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';
import 'package:vsasr_app/src/video/video_timeline.dart';
import 'package:vsasr_app/src/video/hard_subtitle_encoder.dart';
import 'package:vsasr_app/src/video/video_subtitle_cache.dart';
import 'package:vsasr_app/src/video/video_playlist_store.dart';
import 'package:vsasr_app/src/video/video_playlist_coordinator.dart';
import 'package:vsasr_app/src/video/video_player_widgets.dart';
import 'package:vsasr_app/src/video/video_playlist_view.dart';
import 'package:vsasr_app/src/video/video_cache_manager_dialog.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_page.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/ui/background_task_center.dart';

/// 选择视频文件，取消时返回 null。
typedef PickVideoFile = Future<String?> Function();

/// 选择多个视频文件加入播放列表。
typedef PickVideoFiles = Future<List<String>> Function();

/// 保存视频配套字幕文件，测试可以注入内存实现。
typedef SaveVideoSubtitleFile = Future<String?> Function(
  String fileName,
  String content,
);

/// 选择硬字幕视频输出路径；测试可以注入本地临时路径。
typedef SaveHardSubtitleVideo = Future<String?> Function(String fileName);

class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.controller,
    required this.transcription,
    this.pickFile,
    this.pickFiles,
    this.pickDirectory,
    this.pickSubtitleFile,
    this.saveSubtitleFile,
    this.saveHardSubtitleVideo,
    this.hardSubtitleEncoder,
    this.settings,
    this.translationProviderResolver,
    this.subtitleCache,
    this.playlistStore,
    this.backgroundTasks,
  });

  final VideoPlaybackController controller;
  final TranscribeController transcription;
  final PickVideoFile? pickFile;
  final PickVideoFiles? pickFiles;
  final Future<String?> Function()? pickDirectory;
  final PickSubtitleFile? pickSubtitleFile;
  final SaveVideoSubtitleFile? saveSubtitleFile;
  final SaveHardSubtitleVideo? saveHardSubtitleVideo;
  final HardSubtitleEncoder? hardSubtitleEncoder;
  final AppSettingsRepository? settings;
  final Future<TranslationProvider?> Function()? translationProviderResolver;
  final VideoSubtitleCache? subtitleCache;
  final VideoPlaylistStore? playlistStore;
  final BackgroundTaskRegistry? backgroundTasks;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  SubtitleStyle _subtitleStyle = const SubtitleStyle();
  VideoSubtitleDisplayMode _subtitleDisplayMode = VideoSubtitleDisplayMode.off;
  bool _encodingHardSubtitles = false;
  bool _addingDirectory = false;
  double? _hardSubtitleProgress;
  bool _translatingSubtitles = false;
  double? _translationProgress;
  int _translationGeneration = 0;
  int _videoQuarterTurns = 0;

  late final VideoPlaylistCoordinator _playlistCoordinator =
      VideoPlaylistCoordinator(
        controller: widget.controller,
        transcription: widget.transcription,
        settings: widget.settings,
        translationProviderResolver: widget.translationProviderResolver,
        subtitleCache: widget.subtitleCache,
        playlistStore: widget.playlistStore,
        requestTranslationDisclosure: () async {
          if (!mounted) return false;
          return confirmThirdPartyTranslation(context);
        },
        onTranslationPreferenceChanged: (bool enabled) =>
            _saveVideoSubtitleSettings(),
      );

  VideoSubtitleCache get _subtitleCache => _playlistCoordinator.subtitleCache;

  @override
  void initState() {
    super.initState();
    _playlistCoordinator.init();
    unawaited(_loadVideoPreferences());
  }

  Future<void> _loadVideoPreferences() async {
    final AppSettingsRepository? repository = widget.settings;
    try {
      final SubtitleStyle style = repository == null
          ? const SubtitleStyle()
          : await repository.loadSubtitleStyle();
      final VideoSubtitleSettings settings = repository == null
          ? const VideoSubtitleSettings()
          : await repository.loadVideoSubtitleSettings();
      _playlistCoordinator.setProcessingPreferences(
        translationEnabled: false,
        cacheEnabled: settings.cacheEnabled,
      );
      await _playlistCoordinator.loadCacheDirectory();
      if (!mounted) return;
      setState(() {
        _subtitleStyle = style;
        _subtitleDisplayMode = VideoSubtitleDisplayMode.off;
      });
      unawaited(_playlistCoordinator.refreshCacheSummary());
    } on Object {
      // 偏好或目录暂不可用时继续使用默认值，不阻塞视频页打开。
    }
  }

  @override
  void dispose() {
    _translationGeneration++;
    widget.backgroundTasks?.remove('videoSubtitleTranslation');
    widget.backgroundTasks?.remove('videoHardSubtitleEncoding');
    _playlistCoordinator.dispose();
    super.dispose();
  }

  void _syncTranslationTask(String mediaPath) {
    if (!mounted || !_translatingSubtitles) return;
    widget.backgroundTasks?.upsert(
      RegisteredBackgroundTask(
        id: 'videoSubtitleTranslation',
        title: '视频字幕翻译',
        detail: p.basename(mediaPath),
        icon: Icons.translate,
        progress: _translationProgress,
        indeterminate: _translationProgress == null,
        actions: <BackgroundTaskAction>[
          BackgroundTaskAction(
            label: '取消',
            icon: Icons.stop_circle_outlined,
            onPressed: _cancelSubtitleTranslation,
          ),
        ],
      ),
    );
  }

  Future<void> _cancelSubtitleTranslation() async {
    if (!_translatingSubtitles) return;
    _translationGeneration++;
    if (mounted) {
      setState(() {
        _translatingSubtitles = false;
        _translationProgress = null;
      });
      widget.backgroundTasks?.remove('videoSubtitleTranslation');
    }
  }

  void _syncHardSubtitleTask(String mediaPath) {
    if (!mounted || !_encodingHardSubtitles) return;
    widget.backgroundTasks?.upsert(
      RegisteredBackgroundTask(
        id: 'videoHardSubtitleEncoding',
        title: '硬字幕视频编码',
        detail: p.basename(mediaPath),
        icon: Icons.movie_creation_outlined,
        progress: _hardSubtitleProgress,
        indeterminate: _hardSubtitleProgress == null,
      ),
    );
  }

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

  Future<List<String>> _pickFiles() async {
    final PickVideoFiles? injected = widget.pickFiles;
    if (injected != null) return injected();
    final List<PlatformFile> picked = await FilePicker.pickFiles(
      dialogTitle: '添加视频到播放列表',
      type: FileType.custom,
      allowedExtensions: kVideoExtensions,
    );
    return picked
        .map((PlatformFile file) => file.path)
        .whereType<String>()
        .toList(growable: false);
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
      _playlistCoordinator.storePlaylistResult(mediaPath, result);
      _setSubtitleLoadMode(VideoSubtitleLoadMode.existingOnly);
      widget.transcription.applyImportedResult(result, mediaPath: mediaPath);
      if (_playlistCoordinator.subtitleCacheEnabled) {
        unawaited(_playlistCoordinator.writeSubtitleCache(mediaPath, result));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已加载字幕：${selected.name}')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载字幕失败：$error')));
    }
  }

  Future<String?> _saveSubtitleFile(String fileName, String content) async {
    final SaveVideoSubtitleFile? injected = widget.saveSubtitleFile;
    if (injected != null) return injected(fileName, content);
    final Uri? saved = await FilePicker.saveFile(
      dialogTitle: '导出视频字幕',
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(content)),
      mimeType: fileName.endsWith('.json') ? 'application/json' : 'text/plain',
    );
    if (saved == null) return null;
    return saved.isScheme('file') ? saved.toFilePath() : saved.toString();
  }

  Future<void> _exportSubtitles(TranscriptionResult result) async {
    final String? mediaPath = widget.controller.filePath;
    if (mediaPath == null || widget.transcription.busy) return;
    final String? format = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('导出视频配套字幕'),
        children: <Widget>[
          for (final String value in kSubtitleFormats)
            SimpleDialogOption(
              key: Key('videoExportFormat-$value'),
              onPressed: () => Navigator.of(context).pop(value),
              child: Text(value.toUpperCase()),
            ),
        ],
      ),
    );
    if (format == null || !mounted) return;
    try {
      final String fileName =
          '${p.basenameWithoutExtension(mediaPath)}.$format';
      final String? saved = await _saveSubtitleFile(
        fileName,
        renderSubtitles(result, format),
      );
      if (!mounted || saved == null) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出视频配套字幕：$saved')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出字幕失败：$error')));
    }
  }

  Future<String?> _saveHardSubtitleVideo(String fileName) async {
    final SaveHardSubtitleVideo? injected = widget.saveHardSubtitleVideo;
    if (injected != null) return injected(fileName);
    final Uri? saved = await FilePicker.saveFile(
      dialogTitle: '导出硬字幕视频',
      fileName: fileName,
      bytes: Uint8List(0),
      mimeType: 'video/mp4',
    );
    if (saved == null) return null;
    if (!saved.isScheme('file') &&
        !(Platform.isAndroid && saved.isScheme('content'))) {
      throw const HardSubtitleEncodeException('当前平台只能把硬字幕视频保存到本地文件路径');
    }
    return saved.isScheme('file') ? saved.toFilePath() : saved.toString();
  }

  Future<void> _encodeHardSubtitles(TranscriptionResult result) async {
    final String? inputPath = widget.controller.filePath;
    if (inputPath == null ||
        widget.transcription.busy ||
        _encodingHardSubtitles) {
      return;
    }
    if (Platform.isIOS) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('iOS 暂不支持硬字幕视频编码')));
      return;
    }
    final String fileName =
        '${p.basenameWithoutExtension(inputPath)}_hard_subtitles.mp4';
    try {
      final String? outputPath = await _saveHardSubtitleVideo(fileName);
      if (outputPath == null || !mounted) return;
      setState(() {
        _encodingHardSubtitles = true;
        _hardSubtitleProgress = 0;
      });
      _syncHardSubtitleTask(inputPath);
      final HardSubtitleEncoder encoder =
          widget.hardSubtitleEncoder ??
          (Platform.isAndroid
              ? AndroidHardSubtitleEncoder()
              : FfmpegHardSubtitleEncoder());
      await encoder.encode(
        inputPath: inputPath,
        outputPath: outputPath,
        result: result,
        style: _subtitleStyle,
        onProgress: (double? progress) {
          if (!mounted) return;
          setState(() => _hardSubtitleProgress = progress);
          _syncHardSubtitleTask(inputPath);
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('硬字幕视频已导出：$outputPath')));
    } on Object catch (error) {
      if (!mounted) return;
      final String message = error is HardSubtitleEncodeException
          ? error.message
          : '$error';
      widget.backgroundTasks?.recordFailure(
        title: '硬字幕视频编码',
        message: message,
        filePath: inputPath,
      );
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('硬字幕编码失败：$message')));
    } finally {
      if (mounted) {
        setState(() {
          _encodingHardSubtitles = false;
          _hardSubtitleProgress = null;
        });
        widget.backgroundTasks?.remove('videoHardSubtitleEncoding');
      }
    }
  }

  Future<void> _editSubtitleStyle() async {
    SubtitleStyle? next = await showDialog<SubtitleStyle>(
      context: context,
      builder: (BuildContext context) =>
          _SubtitleStyleDialog(initialStyle: _subtitleStyle),
    );
    if (next == null || !mounted) return;
    try {
      final AppSettingsRepository? repository = widget.settings;
      if (repository != null) await repository.saveSubtitleStyle(next);
      if (!mounted) return;
      setState(() => _subtitleStyle = next);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('字幕样式已保存')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存字幕样式失败：$error')));
    }
  }

  Future<void> _openVideo() async {
    final String? path = await _pickFile();
    if (path == null) return;
    await _playlistCoordinator.replaceWith(path);
  }

  Future<void> _openTranscribedVideo() async {
    final String? path = widget.transcription.filePath;
    if (path == null) return;
    final TranscriptionResult? result = widget.transcription.result;
    await _playlistCoordinator.replaceWith(path, result: result);
  }

  Future<void> _addToPlaylist() async {
    final List<String> selected = await _pickFiles();
    if (selected.isEmpty || !mounted) return;
    await _playlistCoordinator.addPaths(selected);
  }

  Future<void> _addDirectoryToPlaylist() async {
    if (_addingDirectory) return;
    setState(() => _addingDirectory = true);
    try {
      final path =
          await (widget.pickDirectory?.call() ??
              FilePicker.getDirectoryPath(dialogTitle: '选择视频文件夹'));
      if (path == null || !mounted) return;
      final paths = <String>[];
      await for (final entry in Directory(path).list(followLinks: false)) {
        if (entry is File &&
            kVideoExtensions.contains(
              p.extension(entry.path).replaceFirst('.', '').toLowerCase(),
            )) {
          paths.add(entry.path);
        }
      }
      if (!mounted) return;
      paths.sort(compareMediaNames);
      if (paths.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('所选文件夹当前层没有支持的视频文件')));
        return;
      }
      await _playlistCoordinator.addPaths(paths);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('添加视频文件夹失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _addingDirectory = false);
    }
  }

  Future<void> _saveVideoSubtitleSettings() async {
    final AppSettingsRepository? repository = widget.settings;
    if (repository == null) return;
    await repository.saveVideoSubtitleSettings(
      VideoSubtitleSettings(
        subtitlesEnabled: _subtitleDisplayMode != VideoSubtitleDisplayMode.off,
        translationEnabled: _playlistCoordinator.translationEnabled,
        cacheEnabled: _playlistCoordinator.subtitleCacheEnabled,
        displayMode: _subtitleDisplayMode,
      ),
    );
  }

  void _setSubtitleLoadMode(VideoSubtitleLoadMode mode) {
    if (mode != VideoSubtitleLoadMode.off &&
        widget.controller.selectedEmbeddedSubtitleTrackId != null) {
      unawaited(widget.controller.selectEmbeddedSubtitleTrack(null));
    }
    _playlistCoordinator.setSubtitleLoadMode(mode);
    setState(
      () => _subtitleDisplayMode = mode == VideoSubtitleLoadMode.off
          ? VideoSubtitleDisplayMode.off
          : VideoSubtitleDisplayMode.original,
    );
  }

  void _setSubtitleDisplayMode(VideoSubtitleDisplayMode mode) {
    if (mode != VideoSubtitleDisplayMode.off) {
      if (widget.controller.selectedEmbeddedSubtitleTrackId != null) {
        unawaited(widget.controller.selectEmbeddedSubtitleTrack(null));
      }
    }
    setState(() => _subtitleDisplayMode = mode);
    unawaited(_saveVideoSubtitleSettings());
  }

  Future<void> _setTranslationEnabled(bool enabled) async {
    if (enabled && !_playlistCoordinator.subtitlesEnabled) return;
    if (enabled && !await _playlistCoordinator.ensureTranslationDisclosure()) {
      return;
    }
    _playlistCoordinator.setTranslationEnabled(enabled);
    await _saveVideoSubtitleSettings();
  }

  void _setSubtitleCacheEnabled(bool enabled) {
    _playlistCoordinator.setSubtitleCacheEnabled(enabled);
    unawaited(_saveVideoSubtitleSettings());
  }

  void _seekVideoBy(Duration offset) {
    final VideoPlaybackController controller = widget.controller;
    if (controller.filePath == null || controller.busy) return;
    unawaited(controller.seek(controller.position + offset));
  }

  Future<void> _translate() async {
    if (_translatingSubtitles) return;
    final String? mediaPath = widget.controller.filePath;
    final TranscriptionResult? result = mediaPath == null
        ? null
        : _playlistCoordinator.resultFor(mediaPath) ??
              (widget.transcription.filePath == mediaPath
                  ? widget.transcription.result
                  : null);
    if (result == null || mediaPath == null || widget.transcription.busy) {
      return;
    }
    final int generation = ++_translationGeneration;
    setState(() {
      _translatingSubtitles = true;
      _translationProgress = 0;
    });
    _syncTranslationTask(mediaPath);
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
        if (!await _playlistCoordinator.ensureTranslationDisclosure()) return;
        if (!_playlistCoordinator.translationEnabled) {
          _playlistCoordinator.setTranslationEnabled(true);
          unawaited(_saveVideoSubtitleSettings());
        }
        final TranscriptionResult translated = await translateResult(
          result,
          provider,
          to: settings.targetLanguage,
          batchSize: 8,
          initialBatchSize: 1,
          maxConcurrentBatches: 3,
          prioritySegmentIndex: _translationPriorityIndex(result),
          skipTranslated: true,
          isCancelled: () => !mounted || generation != _translationGeneration,
          onPartialResult: (TranscriptionResult partial, int done, int total) {
            if (!mounted || generation != _translationGeneration) return;
            _translationProgress = total > 0 ? done / total : null;
            _syncTranslationTask(mediaPath);
            _playlistCoordinator.storePlaylistResult(mediaPath, partial);
            if (widget.controller.filePath == mediaPath &&
                !widget.transcription.busy) {
              widget.transcription.applyImportedResult(
                partial,
                mediaPath: mediaPath,
              );
              setState(() {
                _subtitleDisplayMode = VideoSubtitleDisplayMode.bilingual;
              });
            }
          },
        );
        if (mounted &&
            generation == _translationGeneration &&
            widget.controller.filePath == mediaPath) {
          setState(() {
            _subtitleDisplayMode = VideoSubtitleDisplayMode.bilingual;
            _translationProgress = 1;
          });
          _syncTranslationTask(mediaPath);
          unawaited(_saveVideoSubtitleSettings());
        }
        _playlistCoordinator.storePlaylistResult(mediaPath, translated);
        if (widget.controller.filePath == mediaPath &&
            !widget.transcription.busy) {
          widget.transcription.applyImportedResult(
            translated,
            mediaPath: mediaPath,
          );
        }
        if (_playlistCoordinator.subtitleCacheEnabled) {
          unawaited(
            _playlistCoordinator.writeSubtitleCache(mediaPath, translated),
          );
        }
      } finally {
        if (provider is ClosableTranslationProvider) provider.close();
      }
    } on Object catch (error) {
      if (!mounted || generation != _translationGeneration) return;
      widget.backgroundTasks?.recordFailure(
        title: '视频字幕翻译',
        message: '翻译服务请求失败（${error.runtimeType}）',
        filePath: mediaPath,
      );
      messenger.showSnackBar(SnackBar(content: Text('翻译失败：$error')));
    } finally {
      if (mounted && generation == _translationGeneration) {
        setState(() {
          _translatingSubtitles = false;
          _translationProgress = null;
        });
        widget.backgroundTasks?.remove('videoSubtitleTranslation');
      }
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
      glossary: settings.glossary,
    );
  }

  int _translationPriorityIndex(TranscriptionResult result) {
    final double seconds =
        widget.controller.position.inMicroseconds /
        Duration.microsecondsPerSecond;
    final int index = result.segments.indexWhere(
      (Segment segment) => segment.end >= seconds,
    );
    return index < 0 ? 0 : index;
  }

  Future<void> _openEditor(TranscriptionResult result) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SubtitleEditorPage(
          initialResult: result,
          player: widget.controller,
          onSave: _applyEditedResult,
        ),
      ),
    );
  }

  void _applyEditedResult(TranscriptionResult result) {
    final String? path = widget.controller.filePath;
    if (path == null) return;
    _playlistCoordinator.storePlaylistResult(path, result);
    widget.transcription.applyImportedResult(result, mediaPath: path);
    if (_playlistCoordinator.subtitleCacheEnabled) {
      unawaited(_playlistCoordinator.writeSubtitleCache(path, result));
    }
  }

  Future<void> _selectEmbeddedSubtitleTrack(
    VideoPlaybackController video,
  ) async {
    const disabled = '__disabled__';
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择视频内嵌字幕'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, disabled),
            child: Row(
              children: <Widget>[
                Icon(
                  video.selectedEmbeddedSubtitleTrackId == null
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                const SizedBox(width: 8),
                const Text('关闭内嵌字幕'),
              ],
            ),
          ),
          for (final track in video.embeddedSubtitleTracks)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, track.id),
              child: Row(
                children: <Widget>[
                  Icon(
                    video.selectedEmbeddedSubtitleTrackId == track.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      [
                        if ((track.title ?? '').trim().isNotEmpty) track.title!,
                        if ((track.language ?? '').trim().isNotEmpty)
                          track.language!,
                        if ((track.title ?? '').trim().isEmpty &&
                            (track.language ?? '').trim().isEmpty)
                          '字幕轨 ${track.id}',
                      ].join(' · '),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    if (selected != disabled) {
      _setSubtitleLoadMode(VideoSubtitleLoadMode.off);
    }
    await video.selectEmbeddedSubtitleTrack(
      selected == disabled ? null : selected,
    );
  }

  Future<void> _manageSubtitleCache() async {
    TranslationApiSettings translationSettings = const TranslationApiSettings();
    try {
      if (widget.settings != null) {
        translationSettings = await widget.settings!
            .loadTranslationApiSettings();
      }
    } on Object {
      // 配置损坏时仍可打开缓存管理器，并按默认作用域显示条目。
    }
    late VideoSubtitleCacheSummary summary;
    try {
      summary = await _playlistCoordinator.inspectCache(translationSettings);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取字幕缓存失败：$error')));
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => VideoSubtitleCacheDialog(
        cache: _subtitleCache,
        initialSummary: summary,
        protectedMediaPaths: _playlistCoordinator.protectedCachePaths,
        cacheDirectory: _playlistCoordinator.cacheDirectory,
        configurationScope: _playlistCoordinator.videoSubtitleCacheScope(
          translationSettings,
        ),
      ),
    );
    await _playlistCoordinator.refreshCacheSummary();
  }

  Widget _buildSubtitleToolsMenu({
    required VideoPlaybackController video,
    required bool transcribedVideo,
    required bool hasLinkedResult,
    required TranscriptionResult? result,
  }) {
    return MenuAnchor(
      menuChildren: <Widget>[
        if (transcribedVideo)
          MenuItemButton(
            onPressed: video.busy ? null : _openTranscribedVideo,
            leadingIcon: const Icon(Icons.subtitles_outlined),
            child: const Text('加载已转写视频'),
          ),
        if (video.filePath != null)
          MenuItemButton(
            key: const Key('videoImportSubtitle'),
            onPressed: video.busy || widget.transcription.busy
                ? null
                : _importSubtitle,
            leadingIcon: const Icon(Icons.file_open_outlined),
            child: const Text('加载外部字幕'),
          ),
        if (video.embeddedSubtitleTracks.isNotEmpty)
          MenuItemButton(
            key: const Key('videoEmbeddedSubtitleTrack'),
            onPressed: video.busy
                ? null
                : () => _selectEmbeddedSubtitleTrack(video),
            leadingIcon: const Icon(Icons.closed_caption_outlined),
            child: const Text('选择内嵌字幕轨'),
          ),
        if (hasLinkedResult && result != null) ...<Widget>[
          MenuItemButton(
            key: const Key('videoSubtitleEditor'),
            onPressed: video.busy ? null : () => _openEditor(result),
            leadingIcon: const Icon(Icons.edit_note),
            child: const Text('编辑字幕'),
          ),
          MenuItemButton(
            key: const Key('videoTranslateSubtitle'),
            onPressed:
                video.busy || widget.transcription.busy || _translatingSubtitles
                ? null
                : _translate,
            leadingIcon: const Icon(Icons.translate),
            child: const Text('翻译当前字幕'),
          ),
          MenuItemButton(
            key: const Key('videoExportSubtitles'),
            onPressed:
                video.busy ||
                    widget.transcription.busy ||
                    _encodingHardSubtitles
                ? null
                : () => _exportSubtitles(result),
            leadingIcon: const Icon(Icons.file_download_outlined),
            child: const Text('导出字幕'),
          ),
          MenuItemButton(
            key: const Key('videoBurnSubtitles'),
            onPressed:
                video.busy ||
                    widget.transcription.busy ||
                    _encodingHardSubtitles
                ? null
                : () => _encodeHardSubtitles(result),
            leadingIcon: const Icon(Icons.local_fire_department_outlined),
            child: const Text('生成硬字幕视频'),
          ),
        ],
        if (video.filePath != null)
          MenuItemButton(
            key: const Key('videoSubtitleStyle'),
            onPressed: video.busy || _encodingHardSubtitles
                ? null
                : _editSubtitleStyle,
            leadingIcon: const Icon(Icons.format_color_text_outlined),
            child: const Text('字幕样式'),
          ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) =>
              OutlinedButton.icon(
                key: const Key('videoSubtitleTools'),
                onPressed: transcribedVideo || video.filePath != null
                    ? controller.open
                    : null,
                icon: const Icon(Icons.subtitles_outlined),
                label: const Text('字幕工具'),
              ),
    );
  }

  Widget _buildPlaylist() => VideoPlaylistView(
    paths: _playlistCoordinator.playlist,
    currentIndex: _playlistCoordinator.currentPlaylistIndex,
    statuses: _playlistCoordinator.playlistStatus,
    processingPath: _playlistCoordinator.processingPath,
    onOpen: (int index) =>
        unawaited(_playlistCoordinator.openPlaylistVideo(index)),
    onReorder: _playlistCoordinator.reorderPlaylist,
    onCancel: _playlistCoordinator.cancelPlaylistItem,
    onRetry: _playlistCoordinator.retryPlaylistItem,
    onDelete: (int index) =>
        unawaited(_playlistCoordinator.removePlaylistItem(index)),
  );

  Future<void> _showPlaylist() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 440,
          height: 500,
          child: ListenableBuilder(
            listenable: _playlistCoordinator,
            builder: (context, _) => _buildPlaylist(),
          ),
        ),
      ),
    );
  }

  String _subtitleModeLabel(VideoSubtitleLoadMode mode) => switch (mode) {
    VideoSubtitleLoadMode.off => '字幕：关闭',
    VideoSubtitleLoadMode.existingOnly => '字幕：仅加载已有',
    VideoSubtitleLoadMode.recognizeMissing => '字幕：缺失时识别',
  };

  Widget _buildAddMenu(VideoPlaybackController video) {
    return MenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          key: const Key('videoAddPlaylist'),
          onPressed: video.busy ? null : _addToPlaylist,
          leadingIcon: const Icon(Icons.playlist_add),
          child: const Text('添加视频文件'),
        ),
        MenuItemButton(
          key: const Key('videoAddDirectory'),
          onPressed: video.busy || _addingDirectory
              ? null
              : _addDirectoryToPlaylist,
          leadingIcon: const Icon(Icons.folder_open),
          child: Text(_addingDirectory ? '正在添加…' : '选择文件夹'),
        ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) =>
              OutlinedButton.icon(
                key: const Key('videoAddMenu'),
                onPressed: controller.open,
                icon: const Icon(Icons.add),
                label: const Text('添加'),
              ),
    );
  }

  Widget _buildSubtitleModeMenu() {
    return PopupMenuButton<VideoSubtitleLoadMode>(
      key: const Key('videoSubtitleLoadMode'),
      initialValue: _playlistCoordinator.subtitleLoadMode,
      onSelected: _setSubtitleLoadMode,
      itemBuilder: (context) => const [
        PopupMenuItem(
          key: Key('videoSubtitleModeOff'),
          value: VideoSubtitleLoadMode.off,
          child: Text('关闭字幕'),
        ),
        PopupMenuItem(
          key: Key('videoSubtitleModeExisting'),
          value: VideoSubtitleLoadMode.existingOnly,
          child: Text('仅加载已有字幕'),
        ),
        PopupMenuItem(
          key: Key('videoSubtitleModeRecognize'),
          value: VideoSubtitleLoadMode.recognizeMissing,
          child: Text('缺失时自动识别'),
        ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.closed_caption_outlined, size: 18),
              const SizedBox(width: 8),
              Text(_subtitleModeLabel(_playlistCoordinator.subtitleLoadMode)),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMoreMenu() {
    return MenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          key: const Key('videoRotateClockwise'),
          onPressed: () => setState(() {
            _videoQuarterTurns = (_videoQuarterTurns + 1) % 4;
          }),
          leadingIcon: const Icon(Icons.rotate_right),
          child: Text(
            _videoQuarterTurns == 0
                ? '顺时针旋转 90°'
                : '顺时针旋转 90°（当前 ${_videoQuarterTurns * 90}°）',
          ),
        ),
        MenuItemButton(
          key: const Key('videoCacheToggle'),
          onPressed: () => _setSubtitleCacheEnabled(
            !_playlistCoordinator.subtitleCacheEnabled,
          ),
          leadingIcon: Icon(
            _playlistCoordinator.subtitleCacheEnabled
                ? Icons.check
                : Icons.cached_outlined,
          ),
          child: const Text('缓存后续字幕'),
        ),
        MenuItemButton(
          key: const Key('videoSubtitleCacheManager'),
          onPressed: _manageSubtitleCache,
          leadingIcon: const Icon(Icons.storage_outlined),
          child: const Text('管理字幕缓存'),
        ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) =>
              OutlinedButton.icon(
                key: const Key('videoMoreOptions'),
                onPressed: controller.open,
                icon: const Icon(Icons.more_horiz),
                label: const Text('更多'),
              ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.controller,
        widget.transcription,
        _playlistCoordinator,
      ]),
      builder: (BuildContext context, Widget? _) {
        final VideoPlaybackController video = widget.controller;
        final String? currentPath = video.filePath;
        final TranscriptionResult? result = currentPath == null
            ? null
            : _playlistCoordinator.resultFor(currentPath) ??
                  (widget.transcription.filePath == currentPath
                      ? widget.transcription.result
                      : null);
        final bool hasLinkedResult =
            _playlistCoordinator.subtitlesEnabled &&
            result != null &&
            currentPath != null;
        final Segment? current =
            hasLinkedResult &&
                _subtitleDisplayMode != VideoSubtitleDisplayMode.off
            ? activeSegment(result.segments, video.position)
            : null;
        final String? transcribedPath = widget.transcription.filePath;
        final String transcribedExtension = transcribedPath == null
            ? ''
            : p.extension(transcribedPath).replaceFirst('.', '').toLowerCase();
        final bool transcribedVideo =
            transcribedPath != null &&
            kVideoExtensions.contains(transcribedExtension);

        final Widget content = Column(
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
                  _buildAddMenu(video),
                  _buildSubtitleModeMenu(),
                  FilterChip(
                    key: const Key('videoAutoTranslate'),
                    label: const Text('自动翻译'),
                    selected: _playlistCoordinator.translationEnabled,
                    onSelected: _playlistCoordinator.subtitlesEnabled
                        ? (enabled) =>
                              unawaited(_setTranslationEnabled(enabled))
                        : null,
                  ),
                  _buildSubtitleToolsMenu(
                    video: video,
                    transcribedVideo: transcribedVideo,
                    hasLinkedResult: hasLinkedResult,
                    result: result,
                  ),
                  OutlinedButton.icon(
                    key: const Key('videoShowPlaylist'),
                    onPressed: _showPlaylist,
                    icon: const Icon(Icons.queue_play_next),
                    label: Text(
                      '播放列表 (${_playlistCoordinator.playlist.length})',
                    ),
                  ),
                  _buildMoreMenu(),
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
            if (widget.transcription.stage == JobStage.translating ||
                widget.transcription.stage == JobStage.decoding ||
                widget.transcription.stage ==
                    JobStage.transcribing) ...<Widget>[
              LinearProgressIndicator(value: widget.transcription.progress),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(widget.transcription.statusText),
              ),
            ],
            if (_encodingHardSubtitles) ...<Widget>[
              LinearProgressIndicator(value: _hardSubtitleProgress),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(
                  _hardSubtitleProgress == null
                      ? '正在生成硬字幕视频…'
                      : '正在生成硬字幕视频… ${(_hardSubtitleProgress! * 100).round()}%',
                ),
              ),
            ],
            if (_translatingSubtitles) ...<Widget>[
              LinearProgressIndicator(value: _translationProgress),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(
                  _translationProgress == null
                      ? '正在逐句翻译字幕…'
                      : '正在逐句翻译字幕… ${(_translationProgress! * 100).round()}%',
                ),
              ),
            ],
            Expanded(
              flex: hasLinkedResult ? 3 : 4,
              child: VideoSurface(
                controller: video,
                current: current,
                style: _subtitleStyle,
                displayMode: _subtitleDisplayMode,
                quarterTurns: _videoQuarterTurns,
                controls: video.filePath == null
                    ? null
                    : VideoPlaybackControls(
                        controller: video,
                        onPrevious:
                            _playlistCoordinator.currentPlaylistIndex > 0
                            ? () => unawaited(
                                _playlistCoordinator.openPlaylistVideo(
                                  _playlistCoordinator.currentPlaylistIndex - 1,
                                ),
                              )
                            : null,
                        onNext:
                            _playlistCoordinator.currentPlaylistIndex >= 0 &&
                                _playlistCoordinator.currentPlaylistIndex + 1 <
                                    _playlistCoordinator.playlist.length
                            ? () => unawaited(
                                _playlistCoordinator.openPlaylistVideo(
                                  _playlistCoordinator.currentPlaylistIndex + 1,
                                ),
                              )
                            : null,
                        hasSubtitles: hasLinkedResult,
                        subtitleDisplayMode: _subtitleDisplayMode,
                        onSubtitleDisplayModeChanged: _setSubtitleDisplayMode,
                        translationEnabled:
                            _playlistCoordinator.translationEnabled,
                        onTranslationEnabledChanged: (bool enabled) =>
                            unawaited(_setTranslationEnabled(enabled)),
                      ),
              ),
            ),
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
            if (hasLinkedResult &&
                _subtitleDisplayMode != VideoSubtitleDisplayMode.off)
              Expanded(
                flex: 2,
                child: VideoSubtitleList(
                  controller: video,
                  result: result,
                  displayMode: _subtitleDisplayMode,
                ),
              )
            else if (video.filePath == null)
              const Expanded(
                child: Center(child: Text('打开视频，或先在「文件转写」页签识别一个视频')),
              ),
          ],
        );
        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _handlePlaybackShortcut(const Duration(seconds: -10)),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _handlePlaybackShortcut(const Duration(seconds: 10)),
          },
          child: Focus(
            autofocus: true,
            child: LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth >= 1000
                  ? Row(
                      children: [
                        Expanded(child: content),
                        const VerticalDivider(width: 1),
                        SizedBox(width: 280, child: _buildPlaylist()),
                      ],
                    )
                  : content,
            ),
          ),
        );
      },
    );
  }

  void _handlePlaybackShortcut(Duration offset) {
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    if (!shouldHandleVideoPlaybackShortcut(focused)) {
      return;
    }
    _seekVideoBy(offset);
  }
}

/// 文本编辑器和弹窗拥有方向键；只在播放器页面空白处处理快进/快退。
bool shouldHandleVideoPlaybackShortcut(BuildContext? focused) {
  if (focused == null) return true;
  final Widget widget = focused.widget;
  return widget is! EditableText &&
      widget is! Dialog &&
      widget is! AlertDialog &&
      focused.findAncestorWidgetOfExactType<EditableText>() == null &&
      focused.findAncestorWidgetOfExactType<Dialog>() == null;
}

class _SubtitleStyleDialog extends StatefulWidget {
  const _SubtitleStyleDialog({required this.initialStyle});

  final SubtitleStyle initialStyle;

  @override
  State<_SubtitleStyleDialog> createState() => _SubtitleStyleDialogState();
}

class _SubtitleStyleDialogState extends State<_SubtitleStyleDialog> {
  late double _fontSize = widget.initialStyle.fontSize;
  late int _textColor = widget.initialStyle.textColor;
  late int _backgroundColor = widget.initialStyle.backgroundColor;
  late SubtitlePosition _position = widget.initialStyle.position;

  static const List<int> _textColors = <int>[
    0xFFFFFFFF,
    0xFFFFFF00,
    0xFF00FFFF,
    0xFF00FF00,
  ];
  static const List<int> _backgroundColors = <int>[
    0xC7000000,
    0xB3000000,
    0xCCFFFFFF,
    0x00000000,
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('字幕样式'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('字号：${_fontSize.round()}'),
            Slider(
              key: const Key('subtitleStyleFontSize'),
              min: 12,
              max: 48,
              divisions: 36,
              value: _fontSize,
              label: _fontSize.round().toString(),
              onChanged: (double value) => setState(() => _fontSize = value),
            ),
            DropdownButtonFormField<int>(
              key: ValueKey<String>('subtitleStyleTextColor-$_textColor'),
              initialValue: _textColor,
              decoration: const InputDecoration(labelText: '文字颜色'),
              onChanged: (int? value) {
                if (value != null) setState(() => _textColor = value);
              },
              items: <DropdownMenuItem<int>>[
                for (final int value in _textColors)
                  DropdownMenuItem<int>(
                    value: value,
                    child: _ColorOption(color: Color(value)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: ValueKey<String>(
                'subtitleStyleBackgroundColor-$_backgroundColor',
              ),
              initialValue: _backgroundColor,
              decoration: const InputDecoration(labelText: '背景颜色'),
              onChanged: (int? value) {
                if (value != null) setState(() => _backgroundColor = value);
              },
              items: <DropdownMenuItem<int>>[
                for (final int value in _backgroundColors)
                  DropdownMenuItem<int>(
                    value: value,
                    child: _ColorOption(color: Color(value)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SubtitlePosition>(
              key: ValueKey<String>('subtitleStylePosition-${_position.name}'),
              initialValue: _position,
              decoration: const InputDecoration(labelText: '字幕位置'),
              onChanged: (SubtitlePosition? value) {
                if (value != null) setState(() => _position = value);
              },
              items: <DropdownMenuItem<SubtitlePosition>>[
                for (final SubtitlePosition value in SubtitlePosition.values)
                  DropdownMenuItem<SubtitlePosition>(
                    value: value,
                    child: Text(value.label),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('saveSubtitleStyle'),
          onPressed: () => Navigator.of(context).pop(
            SubtitleStyle(
              fontSize: _fontSize,
              textColor: _textColor,
              backgroundColor: _backgroundColor,
              position: _position,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _ColorOption extends StatelessWidget {
  const _ColorOption({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: color,
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          color.a == 0
              ? '透明'
              : color == Colors.white
              ? '白色'
              : '自定义',
        ),
      ],
    );
  }
}
