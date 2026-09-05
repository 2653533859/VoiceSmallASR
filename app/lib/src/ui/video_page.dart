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
    this.pickSubtitleFile,
    this.saveSubtitleFile,
    this.saveHardSubtitleVideo,
    this.hardSubtitleEncoder,
    this.settings,
    this.translationProviderResolver,
    this.subtitleCache,
    this.playlistStore,
  });

  final VideoPlaybackController controller;
  final TranscribeController transcription;
  final PickVideoFile? pickFile;
  final PickVideoFiles? pickFiles;
  final PickSubtitleFile? pickSubtitleFile;
  final SaveVideoSubtitleFile? saveSubtitleFile;
  final SaveHardSubtitleVideo? saveHardSubtitleVideo;
  final HardSubtitleEncoder? hardSubtitleEncoder;
  final AppSettingsRepository? settings;
  final Future<TranslationProvider?> Function()? translationProviderResolver;
  final VideoSubtitleCache? subtitleCache;
  final VideoPlaylistStore? playlistStore;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  SubtitleStyle _subtitleStyle = const SubtitleStyle();
  VideoSubtitleDisplayMode _subtitleDisplayMode =
      VideoSubtitleDisplayMode.original;
  bool _encodingHardSubtitles = false;
  double? _hardSubtitleProgress;

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
        translationEnabled: settings.translationEnabled,
        cacheEnabled: settings.cacheEnabled,
      );
      await _playlistCoordinator.loadCacheDirectory();
      if (!mounted) return;
      setState(() {
        _subtitleStyle = style;
        _subtitleDisplayMode = settings.displayMode;
      });
      unawaited(_playlistCoordinator.refreshCacheSummary());
    } on Object {
      // 偏好或目录暂不可用时继续使用默认值，不阻塞视频页打开。
    }
  }

  @override
  void dispose() {
    _playlistCoordinator.dispose();
    super.dispose();
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('硬字幕编码失败：$message')));
    } finally {
      if (mounted) {
        setState(() {
          _encodingHardSubtitles = false;
          _hardSubtitleProgress = null;
        });
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

  void _setSubtitleDisplayMode(VideoSubtitleDisplayMode mode) {
    setState(() => _subtitleDisplayMode = mode);
    unawaited(_saveVideoSubtitleSettings());
  }

  Future<void> _setTranslationEnabled(bool enabled) async {
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
        );
        if (mounted) {
          setState(() {
            _subtitleDisplayMode = VideoSubtitleDisplayMode.bilingual;
          });
          unawaited(_saveVideoSubtitleSettings());
        }
        _playlistCoordinator.storePlaylistResult(mediaPath, translated);
        widget.transcription.applyImportedResult(
          translated,
          mediaPath: mediaPath,
        );
        if (_playlistCoordinator.subtitleCacheEnabled) {
          await _playlistCoordinator.writeSubtitleCache(mediaPath, translated);
        }
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
      glossary: settings.glossary,
    );
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
        if (hasLinkedResult && result != null) ...<Widget>[
          MenuItemButton(
            key: const Key('videoSubtitleEditor'),
            onPressed: video.busy ? null : () => _openEditor(result),
            leadingIcon: const Icon(Icons.edit_note),
            child: const Text('编辑字幕'),
          ),
          MenuItemButton(
            key: const Key('videoTranslateSubtitle'),
            onPressed: video.busy || widget.transcription.busy
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

  Widget _buildBackgroundMenu() {
    return MenuAnchor(
      menuChildren: <Widget>[
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
          child: Tooltip(
            message: _playlistCoordinator.cacheDirectory == null
                ? '默认保存到应用数据目录/video_subtitles'
                : '默认位置：${_playlistCoordinator.cacheDirectory}',
            child: const Text('缓存后续字幕'),
          ),
        ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) =>
              OutlinedButton.icon(
                key: const Key('videoBackgroundOptions'),
                onPressed: controller.open,
                icon: const Icon(Icons.tune),
                label: const Text('后台处理'),
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
        final bool hasLinkedResult = result != null && currentPath != null;
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
                  OutlinedButton.icon(
                    key: const Key('videoAddPlaylist'),
                    onPressed: video.busy ? null : _addToPlaylist,
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('添加播放列表'),
                  ),
                  _buildSubtitleToolsMenu(
                    video: video,
                    transcribedVideo: transcribedVideo,
                    hasLinkedResult: hasLinkedResult,
                    result: result,
                  ),
                  _buildBackgroundMenu(),
                  OutlinedButton.icon(
                    key: const Key('videoSubtitleCacheManager'),
                    onPressed: _manageSubtitleCache,
                    icon: const Icon(Icons.storage_outlined),
                    label: Text(
                      '字幕缓存 ${_playlistCoordinator.cacheEntryCount == 0 ? '' : '(${formatVideoCacheBytes(_playlistCoordinator.cacheBytes)})'}',
                    ),
                  ),
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
            if (_playlistCoordinator.playlist.isNotEmpty)
              VideoPlaylistView(
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
            Expanded(
              flex: hasLinkedResult ? 3 : 4,
              child: VideoSurface(
                controller: video,
                current: current,
                style: _subtitleStyle,
                displayMode: _subtitleDisplayMode,
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
          child: Focus(autofocus: true, child: content),
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
