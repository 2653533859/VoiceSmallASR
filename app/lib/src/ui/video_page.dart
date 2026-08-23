/// 视频播放、字幕叠加与时间轴联动页面。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
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

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  bool _translationDisclosureAccepted = false;
  SubtitleStyle _subtitleStyle = const SubtitleStyle();
  bool _subtitlesEnabled = true;
  bool _translationEnabled = false;
  bool _subtitleCacheEnabled = true;
  bool _encodingHardSubtitles = false;
  double? _hardSubtitleProgress;
  final List<String> _playlist = <String>[];
  final Map<String, TranscriptionResult> _playlistResults =
      <String, TranscriptionResult>{};
  final Map<String, String> _playlistStatus = <String, String>{};
  final Map<String, String> _translationWarnings = <String, String>{};
  int _currentPlaylistIndex = -1;
  int _playlistGeneration = 0;
  bool _processingRequested = false;
  Future<void>? _processingFuture;
  Future<void> _translationQueue = Future<void>.value();
  bool _autoAdvancing = false;
  String? _cacheDirectory;

  VideoSubtitleCache get _subtitleCache =>
      widget.subtitleCache ?? const VideoSubtitleCache();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onVideoChanged);
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
      String? cacheDirectory;
      try {
        cacheDirectory = await _subtitleCache.directoryPath();
      } on Object {
        // 路径仅用于提示；实际缓存时会再次尝试创建目录。
      }
      if (!mounted) return;
      setState(() {
        _subtitleStyle = style;
        _subtitlesEnabled = settings.subtitlesEnabled;
        _translationEnabled = settings.translationEnabled;
        _subtitleCacheEnabled = settings.cacheEnabled;
        _cacheDirectory = cacheDirectory;
      });
    } on Object {
      // 偏好或目录暂不可用时继续使用默认值，不阻塞视频页打开。
    }
  }

  @override
  void dispose() {
    _playlistGeneration++;
    widget.controller.removeListener(_onVideoChanged);
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
      _storePlaylistResult(mediaPath, result);
      widget.transcription.applyImportedResult(result, mediaPath: mediaPath);
      if (_subtitleCacheEnabled) {
        unawaited(_writeSubtitleCache(mediaPath, result));
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
    _playlistGeneration++;
    setState(() {
      _playlist
        ..clear()
        ..add(path);
      _currentPlaylistIndex = 0;
    });
    await _openPlaylistVideo(0);
  }

  Future<void> _openTranscribedVideo() async {
    final String? path = widget.transcription.filePath;
    if (path == null) return;
    final TranscriptionResult? result = widget.transcription.result;
    if (result != null) _playlistResults[path] = result;
    _playlistGeneration++;
    setState(() {
      _playlist
        ..clear()
        ..add(path);
      _currentPlaylistIndex = 0;
    });
    await _openPlaylistVideo(0);
  }

  Future<void> _addToPlaylist() async {
    final List<String> selected = await _pickFiles();
    if (selected.isEmpty || !mounted) return;
    final Set<String> known = _playlist.toSet();
    final List<String> additions = selected
        .map((String path) => path.trim())
        .where((String path) => path.isNotEmpty && known.add(path))
        .toList(growable: false);
    if (additions.isEmpty) return;
    final bool openFirst = _currentPlaylistIndex < 0;
    _playlistGeneration++;
    setState(() => _playlist.addAll(additions));
    if (openFirst) {
      await _openPlaylistVideo(0);
    } else {
      _requestPlaylistProcessing();
    }
  }

  Future<void> _openPlaylistVideo(int index, {bool autoplay = false}) async {
    if (index < 0 || index >= _playlist.length) return;
    final String path = _playlist[index];
    final TranscriptionResult? linked = widget.transcription.filePath == path
        ? widget.transcription.result
        : null;
    if (linked != null) _playlistResults[path] = linked;
    _playlistGeneration++;
    setState(() => _currentPlaylistIndex = index);
    await widget.controller.open(path);
    if (!mounted) return;
    if (autoplay &&
        widget.controller.filePath == path &&
        !widget.controller.playing) {
      await widget.controller.playOrPause();
    }
    _requestPlaylistProcessing();
  }

  void _onVideoChanged() {
    if (_autoAdvancing ||
        _currentPlaylistIndex < 0 ||
        _currentPlaylistIndex + 1 >= _playlist.length) {
      return;
    }
    final Duration duration = widget.controller.duration;
    if (duration <= Duration.zero ||
        widget.controller.position <
            duration - const Duration(milliseconds: 250)) {
      return;
    }
    _autoAdvancing = true;
    unawaited(
      _openPlaylistVideo(
        _currentPlaylistIndex + 1,
        autoplay: true,
      ).whenComplete(() {
        _autoAdvancing = false;
      }),
    );
  }

  Future<void> _saveVideoSubtitleSettings() async {
    final AppSettingsRepository? repository = widget.settings;
    if (repository == null) return;
    await repository.saveVideoSubtitleSettings(
      VideoSubtitleSettings(
        subtitlesEnabled: _subtitlesEnabled,
        translationEnabled: _translationEnabled,
        cacheEnabled: _subtitleCacheEnabled,
      ),
    );
  }

  void _setSubtitlesEnabled(bool enabled) {
    setState(() => _subtitlesEnabled = enabled);
    unawaited(_saveVideoSubtitleSettings());
  }

  Future<void> _setTranslationEnabled(bool enabled) async {
    if (enabled && !_translationDisclosureAccepted) {
      final bool confirmed = await confirmThirdPartyTranslation(context);
      if (!confirmed || !mounted) return;
      _translationDisclosureAccepted = true;
    }
    setState(() => _translationEnabled = enabled);
    await _saveVideoSubtitleSettings();
    if (enabled) _requestPlaylistProcessing();
  }

  void _setSubtitleCacheEnabled(bool enabled) {
    setState(() => _subtitleCacheEnabled = enabled);
    unawaited(_saveVideoSubtitleSettings());
    if (enabled) _requestPlaylistProcessing();
  }

  void _requestPlaylistProcessing() {
    _processingRequested = true;
    if (_processingFuture != null) return;
    final Future<void> future = _drainPlaylistProcessing();
    _processingFuture = future;
    unawaited(
      future.whenComplete(() {
        _processingFuture = null;
        if (_processingRequested && mounted) _requestPlaylistProcessing();
      }),
    );
  }

  Future<void> _drainPlaylistProcessing() async {
    while (_processingRequested && mounted) {
      _processingRequested = false;
      await _processPlaylist(_playlistGeneration);
    }
  }

  Future<void> _processPlaylist(int generation) async {
    if (_currentPlaylistIndex < 0 ||
        _currentPlaylistIndex >= _playlist.length) {
      return;
    }
    final List<String> paths = <String>[
      _playlist[_currentPlaylistIndex],
      if (_subtitleCacheEnabled) ..._playlist.skip(_currentPlaylistIndex + 1),
    ];
    final AppSettingsRepository? configuredRepository = widget.settings;
    final TranslationApiSettings translationSettings =
        configuredRepository == null
        ? const TranslationApiSettings()
        : await configuredRepository.loadTranslationApiSettings();
    final String cacheScope = _videoSubtitleCacheScope(translationSettings);
    TranslationProvider? provider;
    bool providerResolved = false;
    Future<TranslationProvider?> resolveProvider() async {
      if (providerResolved) return provider;
      providerResolved = true;
      final Future<TranslationProvider?> Function()? resolver =
          widget.translationProviderResolver;
      provider = resolver == null
          ? await _loadTranslationProvider(
              configuredRepository ?? AppSettingsRepository(),
              translationSettings,
            )
          : await resolver();
      return provider;
    }

    try {
      for (final String path in paths) {
        if (!mounted || generation != _playlistGeneration) return;
        TranscriptionResult? result = _playlistResults[path];
        if (result == null && _subtitleCacheEnabled) {
          result = await _subtitleCache.read(
            path,
            configurationScope: cacheScope,
          );
          if (result != null) {
            _storePlaylistResult(path, result);
            _setPlaylistStatus(path, '已载入字幕缓存');
          }
        }
        if (result == null) {
          _setPlaylistStatus(
            path,
            path == widget.controller.filePath ? '实时转写中' : '后台预转写中',
          );
          try {
            result = await widget.transcription.transcribeVideoStream(
              path,
              onUpdate: (TranscriptionResult update) {
                if (generation != _playlistGeneration) return;
                final TranscriptionResult merged = _mergeTranslations(
                  update,
                  _playlistResults[path],
                );
                _storePlaylistResult(path, merged);
                if (_translationEnabled) {
                  _queueMissingTranslations(
                    path,
                    resolveProvider,
                    translationSettings.targetLanguage,
                    generation,
                  );
                }
              },
            );
            result = _mergeTranslations(result, _playlistResults[path]);
            _storePlaylistResult(path, result);
          } on Object catch (error) {
            _setPlaylistStatus(path, '转写失败：$error');
            continue;
          }
        }
        if (_translationEnabled) {
          _queueMissingTranslations(
            path,
            resolveProvider,
            translationSettings.targetLanguage,
            generation,
          );
          await _translationQueue;
          result = _playlistResults[path] ?? result;
        }
        if (_subtitleCacheEnabled && result.segments.isNotEmpty) {
          try {
            final String saved = await _subtitleCache.write(
              path,
              result,
              configurationScope: cacheScope,
            );
            _cacheDirectory = p.dirname(saved);
            _setPlaylistReadyStatus(path, '字幕已缓存');
          } on Object catch (error) {
            _setPlaylistReadyStatus(path, '字幕可用，缓存失败：$error');
          }
        } else {
          _setPlaylistReadyStatus(path, '字幕已就绪');
        }
        if (path == widget.controller.filePath && !widget.transcription.busy) {
          widget.transcription.applyImportedResult(result, mediaPath: path);
        }
      }
    } finally {
      if (provider is ClosableTranslationProvider) {
        (provider as ClosableTranslationProvider).close();
      }
    }
  }

  void _queueMissingTranslations(
    String path,
    Future<TranslationProvider?> Function() resolveProvider,
    String targetLanguage,
    int generation,
  ) {
    _translationQueue = _translationQueue
        .then<void>((_) async {
          if (!_translationEnabled || generation != _playlistGeneration) return;
          final TranscriptionResult? source = _playlistResults[path];
          if (source == null) return;
          final List<int> missing = <int>[];
          for (int index = 0; index < source.segments.length; index++) {
            final Segment segment = source.segments[index];
            if (segment.isFinal &&
                segment.text.trim().isNotEmpty &&
                segment.translation?.trim().isEmpty != false &&
                !_isChineseSegment(segment, source.language)) {
              missing.add(index);
            }
          }
          if (missing.isEmpty) {
            _setTranslationWarning(path, null);
            return;
          }
          if (!await _ensureTranslationDisclosure()) return;
          final TranslationProvider? translator = await resolveProvider();
          if (translator == null) {
            _setTranslationWarning(path, '未配置翻译 API Key');
            return;
          }
          for (final int index in missing) {
            if (!_translationEnabled || generation != _playlistGeneration) {
              return;
            }
            final TranscriptionResult? current = _playlistResults[path];
            if (current == null || index >= current.segments.length) return;
            final Segment segment = current.segments[index];
            final List<String> translated = await translator.translate(
              <String>[segment.text],
              from: segment.language.trim().isEmpty
                  ? current.language
                  : segment.language,
              to: targetLanguage,
            );
            if (translated.length != 1) {
              throw StateError('翻译服务返回 ${translated.length} 条结果，需要 1 条');
            }
            final List<Segment> segments = <Segment>[...current.segments];
            segments[index] = segment.copyWith(
              translation: translated.single.trim(),
            );
            _storePlaylistResult(path, current.copyWith(segments: segments));
          }
          _setTranslationWarning(path, null);
        })
        .catchError((Object error) {
          _setTranslationWarning(path, '翻译失败：$error');
        });
  }

  Future<bool> _ensureTranslationDisclosure() async {
    if (_translationDisclosureAccepted) return true;
    if (!mounted) return false;
    final bool confirmed = await confirmThirdPartyTranslation(context);
    if (!mounted) return false;
    if (confirmed) {
      _translationDisclosureAccepted = true;
      return true;
    }
    setState(() => _translationEnabled = false);
    unawaited(_saveVideoSubtitleSettings());
    return false;
  }

  void _storePlaylistResult(String path, TranscriptionResult result) {
    _playlistResults[path] = result;
    if (mounted && widget.controller.filePath == path) setState(() {});
  }

  void _setPlaylistStatus(String path, String status) {
    _playlistStatus[path] = status;
    if (mounted) setState(() {});
  }

  void _setTranslationWarning(String path, String? warning) {
    if (warning == null) {
      _translationWarnings.remove(path);
    } else {
      _translationWarnings[path] = warning;
      _setPlaylistStatus(path, '字幕已就绪；$warning');
    }
  }

  void _setPlaylistReadyStatus(String path, String status) {
    final String? warning = _translationWarnings[path];
    _setPlaylistStatus(path, warning == null ? status : '$status；$warning');
  }

  String _videoSubtitleCacheScope(TranslationApiSettings settings) {
    final Map<String, Object?> scope = <String, Object?>{
      'asr': widget.transcription.config.toJson(),
      'translation': _translationEnabled
          ? <String, String>{
              'endpoint': settings.endpoint.trim(),
              'model': settings.model.trim(),
              'target_language': settings.targetLanguage.trim(),
              'glossary': settings.glossary,
            }
          : null,
    };
    return sha256.convert(utf8.encode(jsonEncode(scope))).toString();
  }

  TranscriptionResult _mergeTranslations(
    TranscriptionResult source,
    TranscriptionResult? previous,
  ) {
    if (previous == null) return source;
    final Map<String, String> translations = <String, String>{
      for (final Segment segment in previous.segments)
        if (segment.translation?.trim().isNotEmpty == true)
          _segmentKey(segment): segment.translation!.trim(),
    };
    return source.copyWith(
      segments: source.segments
          .map(
            (Segment segment) => translations[_segmentKey(segment)] == null
                ? segment
                : segment.copyWith(
                    translation: translations[_segmentKey(segment)],
                  ),
          )
          .toList(growable: false),
    );
  }

  Future<void> _translate() async {
    final String? mediaPath = widget.controller.filePath;
    final TranscriptionResult? result = mediaPath == null
        ? null
        : _playlistResults[mediaPath] ??
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
        if (!_translationDisclosureAccepted) {
          final bool confirmed = await confirmThirdPartyTranslation(context);
          if (!confirmed || !mounted) return;
          _translationDisclosureAccepted = true;
        }
        if (!_translationEnabled) {
          setState(() => _translationEnabled = true);
          unawaited(_saveVideoSubtitleSettings());
        }
        final TranscriptionResult translated = await translateResult(
          result,
          provider,
          to: settings.targetLanguage,
        );
        _storePlaylistResult(mediaPath, translated);
        widget.transcription.applyImportedResult(
          translated,
          mediaPath: mediaPath,
        );
        if (_subtitleCacheEnabled) {
          await _writeSubtitleCache(mediaPath, translated);
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
    _storePlaylistResult(path, result);
    widget.transcription.applyImportedResult(result, mediaPath: path);
    if (_subtitleCacheEnabled) {
      unawaited(_writeSubtitleCache(path, result));
    }
  }

  Future<void> _writeSubtitleCache(
    String path,
    TranscriptionResult result,
  ) async {
    try {
      final TranslationApiSettings translationSettings = widget.settings == null
          ? const TranslationApiSettings()
          : await widget.settings!.loadTranslationApiSettings();
      final String saved = await _subtitleCache.write(
        path,
        result,
        configurationScope: _videoSubtitleCacheScope(translationSettings),
      );
      _cacheDirectory = p.dirname(saved);
      _setPlaylistReadyStatus(path, '字幕已缓存');
    } on Object catch (error) {
      _setPlaylistReadyStatus(path, '字幕可用，缓存失败：$error');
    }
  }

  Widget _buildPlaylist(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView.builder(
        key: const Key('videoPlaylist'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        scrollDirection: Axis.horizontal,
        itemCount: _playlist.length,
        itemBuilder: (BuildContext context, int index) {
          final String path = _playlist[index];
          final bool selected = index == _currentPlaylistIndex;
          return SizedBox(
            width: 230,
            child: Card(
              color: selected
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
              child: ListTile(
                dense: true,
                selected: selected,
                leading: Text('${index + 1}'),
                title: Text(
                  p.basename(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  _playlistStatus[path] ?? '等待播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => unawaited(_openPlaylistVideo(index)),
              ),
            ),
          );
        },
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
        final String? currentPath = video.filePath;
        final TranscriptionResult? result = currentPath == null
            ? null
            : _playlistResults[currentPath] ??
                  (widget.transcription.filePath == currentPath
                      ? widget.transcription.result
                      : null);
        final bool hasLinkedResult = result != null && currentPath != null;
        final Segment? current = hasLinkedResult && _subtitlesEnabled
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
                  OutlinedButton.icon(
                    key: const Key('videoAddPlaylist'),
                    onPressed: video.busy ? null : _addToPlaylist,
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('添加播放列表'),
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
                      label: const Text('翻译当前字幕'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('videoExportSubtitles'),
                      onPressed:
                          video.busy ||
                              widget.transcription.busy ||
                              _encodingHardSubtitles
                          ? null
                          : () => _exportSubtitles(result),
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('导出字幕'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('videoBurnSubtitles'),
                      onPressed:
                          video.busy ||
                              widget.transcription.busy ||
                              _encodingHardSubtitles
                          ? null
                          : () => _encodeHardSubtitles(result),
                      icon: const Icon(Icons.local_fire_department_outlined),
                      label: const Text('生成硬字幕视频'),
                    ),
                  ],
                  if (video.filePath != null)
                    OutlinedButton.icon(
                      key: const Key('videoSubtitleStyle'),
                      onPressed: video.busy || _encodingHardSubtitles
                          ? null
                          : _editSubtitleStyle,
                      icon: const Icon(Icons.format_color_text_outlined),
                      label: const Text('字幕样式'),
                    ),
                  FilterChip(
                    key: const Key('videoSubtitlesToggle'),
                    label: const Text('显示字幕'),
                    selected: _subtitlesEnabled,
                    onSelected: _setSubtitlesEnabled,
                  ),
                  FilterChip(
                    key: const Key('videoTranslationToggle'),
                    label: const Text('字幕翻译'),
                    selected: _translationEnabled,
                    onSelected: (bool enabled) =>
                        unawaited(_setTranslationEnabled(enabled)),
                  ),
                  Tooltip(
                    message: _cacheDirectory == null
                        ? '默认保存到应用数据目录/video_subtitles'
                        : '默认位置：$_cacheDirectory',
                    child: FilterChip(
                      key: const Key('videoCacheToggle'),
                      label: const Text('缓存后续字幕'),
                      selected: _subtitleCacheEnabled,
                      onSelected: _setSubtitleCacheEnabled,
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
            if (_playlist.isNotEmpty) _buildPlaylist(context),
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
              child: _VideoSurface(
                controller: video,
                current: current,
                style: _subtitleStyle,
                showTranslation: _translationEnabled,
              ),
            ),
            if (video.filePath != null)
              _PlaybackControls(
                controller: video,
                onPrevious: _currentPlaylistIndex > 0
                    ? () => unawaited(
                        _openPlaylistVideo(_currentPlaylistIndex - 1),
                      )
                    : null,
                onNext:
                    _currentPlaylistIndex >= 0 &&
                        _currentPlaylistIndex + 1 < _playlist.length
                    ? () => unawaited(
                        _openPlaylistVideo(_currentPlaylistIndex + 1),
                      )
                    : null,
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
            if (hasLinkedResult && _subtitlesEnabled)
              Expanded(
                flex: 2,
                child: _SubtitleList(
                  controller: video,
                  result: result,
                  showTranslation: _translationEnabled,
                ),
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
  const _VideoSurface({
    required this.controller,
    required this.current,
    required this.style,
    required this.showTranslation,
  });

  final VideoPlaybackController controller;
  final Segment? current;
  final SubtitleStyle style;
  final bool showTranslation;

  @override
  Widget build(BuildContext context) {
    final Widget? subtitle = current == null
        ? null
        : Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: style.position.alignment,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
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
                      child: Text(
                        <String>[
                          if ((current!.speaker ?? '').trim().isNotEmpty)
                            '【${current!.speaker!.trim()}】',
                          current!.text,
                          if (showTranslation &&
                              (current!.translation ?? '').trim().isNotEmpty)
                            current!.translation!,
                        ].join('\n'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: style.foreground,
                          fontSize: style.fontSize,
                          height: 1.35,
                        ),
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

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.controller,
    this.onPrevious,
    this.onNext,
  });

  final VideoPlaybackController controller;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

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
            tooltip: '上一个视频',
            onPressed: controller.busy ? null : onPrevious,
            icon: const Icon(Icons.skip_previous),
          ),
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
          IconButton(
            tooltip: '下一个视频',
            onPressed: controller.busy ? null : onNext,
            icon: const Icon(Icons.skip_next),
          ),
        ],
      ),
    );
  }
}

class _SubtitleList extends StatelessWidget {
  const _SubtitleList({
    required this.controller,
    required this.result,
    required this.showTranslation,
  });

  final VideoPlaybackController controller;
  final TranscriptionResult result;
  final bool showTranslation;

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
              if ((segment.speaker ?? '').trim().isNotEmpty)
                Text(
                  '【${segment.speaker!.trim()}】',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              Text(segment.text),
              if (showTranslation &&
                  (segment.translation ?? '').trim().isNotEmpty)
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

String _segmentKey(Segment segment) =>
    '${segment.index}:${segment.start}:${segment.end}:${segment.text}';

bool _isChineseSegment(Segment segment, String fallbackLanguage) {
  final String language =
      (segment.language.trim().isEmpty ? fallbackLanguage : segment.language)
          .trim()
          .toLowerCase();
  return language == 'zh' ||
      language == 'zh-cn' ||
      language == 'zh-tw' ||
      language == 'cmn' ||
      language == 'yue' ||
      language.startsWith('zh-');
}
