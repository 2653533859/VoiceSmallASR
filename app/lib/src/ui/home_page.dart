/// 主页面：模型准备、文件转写与实时字幕两个页签、分段列表、导出字幕。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/project/project_file.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/settings/settings_page.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_page.dart';
import 'package:vsasr_app/src/ui/live_controller.dart';
import 'package:vsasr_app/src/ui/batch_page.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/ui/video_page.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/translation/translation_disclosure.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

/// 选择要转写的文件，返回绝对路径；用户取消时返回 null。
typedef PickFile = Future<String?> Function();

/// 检查媒体引用是否仍可读；测试可注入内存或临时文件实现。
typedef MediaFileExists = Future<bool> Function(String path);

/// 保存字幕：给文件名与内容，返回落地位置的描述；用户取消时返回 null。
typedef SaveFile = Future<String?> Function(String fileName, String content);

/// 文件选择器返回的项目文件。Android SAF 可能只有可读字节，没有本地路径。
class PickedProjectFile {
  const PickedProjectFile({required this.name, this.path, this.bytes});

  final String name;
  final String? path;
  final Uint8List? bytes;
}

/// 选择项目文件，测试可注入本地路径或内存字节。
typedef PickProjectFile = Future<PickedProjectFile?> Function();

/// 加载项目文件。测试可注入内存实现，生产环境默认使用 [ProjectFileStore]。
typedef LoadProjectFile = Future<VsasrProject> Function(String path);

/// 创建翻译 provider。生产环境使用可配置的第三方 API，测试可以注入不触网的替身。
typedef TranslationProviderFactory = TranslationProvider Function(
  String apiKey,
);

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    this.live,
    this.video,
    this.pickFile,
    this.pickBatchFiles,
    this.pickProjectFile,
    this.pickSubtitleFile,
    this.loadProjectFile,
    this.saveFile,
    this.autosaveStore,
    this.mediaFileExists,
    this.settings,
    this.translationProviderFactory,
    this.translationProviderResolver,
  });

  final TranscribeController controller;

  /// 实时字幕。为 null 时不显示「实时字幕」页签（不需要麦克风的测试用）。
  final LiveController? live;

  /// 视频播放控制器。为 null 时不显示「视频播放」页签（测试用）。
  final VideoPlaybackController? video;

  /// 文件选择与保存。测试注入替身，默认走 `file_picker`。
  final PickFile? pickFile;
  final PickBatchFiles? pickBatchFiles;
  final PickProjectFile? pickProjectFile;
  final PickSubtitleFile? pickSubtitleFile;
  final LoadProjectFile? loadProjectFile;
  final SaveFile? saveFile;

  /// 自动保存与恢复存储。生产环境使用应用支持目录，测试可注入内存实现。
  final ProjectAutosaveStore? autosaveStore;

  final MediaFileExists? mediaFileExists;

  /// 设置存储。测试注入替身；生产环境由顶层应用复用同一个仓库。
  final AppSettingsRepository? settings;

  final TranslationProviderFactory? translationProviderFactory;
  final Future<TranslationProvider?> Function()? translationProviderResolver;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final BatchTranscriptionController _batch;
  bool _translationDisclosureAccepted = false;
  bool _liveTranslationDisclosureAccepted = false;
  List<String> _recentProjects = <String>[];
  int _recentProjectsGeneration = 0;
  Timer? _autosaveTimer;
  Future<void>? _autosaveFuture;
  int _autosaveRequestedRevision = 0;
  int _autosavedRevision = 0;
  bool _autosaveFailureNotified = false;
  bool _recoveryPromptShown = false;
  bool _detached = false;
  bool _sessionEnded = false;

  AppSettingsRepository get _settingsRepository =>
      widget.settings ?? AppSettingsRepository();

  ProjectAutosaveStore get _autosaveRepository =>
      widget.autosaveStore ?? const FileProjectAutosaveStore();

  @override
  void initState() {
    super.initState();
    _batch = BatchTranscriptionController(transcriber: widget.controller);
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onControllerChanged);
    // build 之后再查模型，避免在 initState 里同步 notifyListeners。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.refreshModel();
      unawaited(_loadRecentProjects());
      unawaited(_loadRecovery());
    });
  }

  void _onControllerChanged() {
    if (_detached) return;
    final TranscribeController controller = widget.controller;
    if (controller.result == null ||
        controller.projectRevision <= _autosavedRevision) {
      return;
    }
    _autosaveRequestedRevision = controller.projectRevision;
    _autosaveFailureNotified = false;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(milliseconds: 400), () {
      _autosaveTimer = null;
      unawaited(_flushAutosave());
    });
  }

  Future<void> _flushAutosave() async {
    if (_detached || _autosaveFuture != null) return;
    final TranscribeController controller = widget.controller;
    final int revision = _autosaveRequestedRevision;
    if (revision <= _autosavedRevision || controller.result == null) return;
    final VsasrProject project;
    try {
      project = controller.projectSnapshot;
    } on Object {
      return;
    }
    final Future<void> operation = _autosaveRepository.save(project);
    _autosaveFuture = operation;
    try {
      await operation;
      _autosavedRevision = revision;
    } on Object catch (error) {
      if (mounted && !_autosaveFailureNotified) {
        _autosaveFailureNotified = true;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('自动保存失败，仍可手动保存项目：$error')));
      }
    } finally {
      if (identical(_autosaveFuture, operation)) _autosaveFuture = null;
      if (!_detached &&
          controller.projectRevision > _autosavedRevision &&
          controller.result != null) {
        _onControllerChanged();
      }
    }
  }

  Future<void> _loadRecovery() async {
    try {
      final bool unclean = await _autosaveRepository
          .wasPreviousSessionUnclean();
      await _autosaveRepository.beginSession();
      if (_detached) {
        await _autosaveRepository.endSession();
        return;
      }
      _sessionEnded = false;
      if (!unclean) return;
      final VsasrProject? project = await _autosaveRepository.load();
      if (!mounted || project == null || _detached) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_recoveryPromptShown && !_detached) {
          unawaited(_showRecoveryPrompt(project));
        }
      });
    } on Object {
      // 恢复快照是辅助数据，读取失败不能阻塞主界面启动。
    }
  }

  Future<void> _showRecoveryPrompt(VsasrProject project) async {
    if (_recoveryPromptShown) return;
    _recoveryPromptShown = true;
    final String mediaName = project.mediaPath == null
        ? '未关联媒体文件'
        : p.basename(project.mediaPath!);
    final bool? recover = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('发现未完成的项目'),
        content: Text('检测到上次退出前的自动保存快照（媒体：$mediaName）。\n是否恢复字幕和译文？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('放弃恢复'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复项目'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (recover == false) {
      try {
        await _autosaveRepository.clear();
      } on Object {
        // 用户已明确放弃；清理失败不影响主界面继续使用。
      }
      return;
    }
    if (recover != true) return;
    try {
      await widget.controller.loadProject(project);
      await _checkProjectMedia();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已恢复上次自动保存的项目')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('恢复项目失败：$error')));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _detached = true;
      _autosaveTimer?.cancel();
      unawaited(_endSessionOnExit());
      return;
    }
    if (state == AppLifecycleState.resumed && _detached) {
      _detached = false;
      unawaited(_beginSession());
    }
  }

  Future<void> _beginSession() async {
    try {
      await _autosaveRepository.beginSession();
      _sessionEnded = false;
    } on Object {
      // 会话锁只是恢复提示的辅助信息，写入失败不阻塞主流程。
    }
  }

  Future<void> _endSessionOnExit() async {
    if (_sessionEnded) return;
    _sessionEnded = true;
    try {
      await _autosaveFuture;
    } on Object {
      // 当前写入失败也不应阻止结束会话。
    }
    try {
      await _autosaveRepository.endSession();
    } on Object {
      // 进程退出时无法保证平台文件操作完成；快照仍保留作下次兜底。
    }
  }

  Future<void> _loadRecentProjects() async {
    final int generation = _recentProjectsGeneration;
    try {
      final List<String> projects = await _settingsRepository
          .loadRecentProjects();
      if (!mounted) return;
      if (generation != _recentProjectsGeneration) return;
      setState(() => _recentProjects = projects);
    } on Object {
      // 最近项目只是辅助入口，偏好存储不可用时不影响主流程。
    }
  }

  Future<void> _rememberRecentProject(String path) async {
    final String? normalizedPath = _normalizeRecentProjectPath(path);
    if (normalizedPath == null) return;
    final int generation = ++_recentProjectsGeneration;
    try {
      final List<String> projects = await _settingsRepository
          .rememberRecentProject(normalizedPath);
      if (!mounted) return;
      if (generation != _recentProjectsGeneration) return;
      setState(() => _recentProjects = projects);
    } on Object {
      // 保存/打开已成功时，最近项目写入失败不应覆盖主结果。
    }
  }

  /// 项目文件的默认读取器使用 dart:io；外部 URI 会先复制到应用支持目录。
  String? _normalizeRecentProjectPath(String path) {
    final String value = path.trim();
    if (value.isEmpty) return null;
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return value;
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || uri.scheme.isEmpty) return value;
    if (uri.scheme == 'file') {
      try {
        return uri.toFilePath();
      } on Object {
        return null;
      }
    }
    return null;
  }

  Future<String?> _projectPathForRecent({
    required VsasrProject project,
    required String? externalPath,
    required String identity,
    bool refreshCache = false,
  }) async {
    if (Platform.isAndroid &&
        externalPath != null &&
        _recentProjects.contains(externalPath) &&
        !refreshCache) {
      return externalPath;
    }
    if (!Platform.isAndroid && externalPath != null) {
      final String? normalized = _normalizeRecentProjectPath(externalPath);
      if (normalized != null) return normalized;
    }
    try {
      return await const ProjectFileStore().cacheForRecentProject(
        project,
        identity: identity,
      );
    } on Object {
      // 最近项目只是辅助入口，缓存失败不应阻断项目打开或保存。
      return null;
    }
  }

  Future<String?> _pickFile() async {
    final PickFile? injected = widget.pickFile;
    if (injected != null) return injected();
    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: '选择音频或视频',
      type: FileType.custom,
      allowedExtensions: kSupportedAudioExtensions,
    );
    return picked?.path;
  }

  Future<List<String>> _pickBatchFiles() async {
    final PickBatchFiles? injected = widget.pickBatchFiles;
    if (injected != null) return injected();
    final List<PlatformFile> picked = await FilePicker.pickFiles(
      dialogTitle: '选择多个音频或视频文件',
      type: FileType.custom,
      allowedExtensions: kSupportedAudioExtensions,
    );
    if (picked.any((PlatformFile file) => file.path == null)) {
      throw const FormatException('批量转写需要可访问的本地文件路径，请逐个选择或先将文件保存到本机');
    }
    return picked
        .map((PlatformFile file) => file.path)
        .whereType<String>()
        .toList(growable: false);
  }

  Future<void> _openBatch() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => BatchPage(
          controller: _batch,
          pickFiles: _pickBatchFiles,
          onTranslate: _translateBatch,
        ),
      ),
    );
  }

  Future<String?> _saveFile(
    String fileName,
    String content, {
    String dialogTitle = '导出字幕',
  }) async {
    final SaveFile? injected = widget.saveFile;
    if (injected != null) return injected(fileName, content);
    // file_picker 12 的 saveFile 自己落盘（Android SAF、macOS sandbox 都由它处理），
    // 因此这里交出字节而不是路径。
    final Uri? saved = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(content)),
      mimeType: fileName.endsWith('.json') ? 'application/json' : 'text/plain',
    );
    if (saved == null) return null;
    return saved.isScheme('file') ? saved.toFilePath() : saved.toString();
  }

  Future<void> _openFile() async {
    final String? path = await _pickFile();
    if (path == null) return;
    await widget.controller.transcribeFile(path);
  }

  Future<PickedProjectFile?> _pickProjectFile() async {
    final PickProjectFile? injected = widget.pickProjectFile;
    if (injected != null) return injected();
    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: '打开 VoiceSmallASR 项目',
      type: FileType.custom,
      allowedExtensions: <String>['json'],
    );
    if (picked == null) return null;
    final String? path = picked.path;
    return PickedProjectFile(
      name: picked.name,
      path: path,
      bytes: path == null ? await picked.readAsBytes() : null,
    );
  }

  Future<SubtitleFileData?> _pickSubtitleFile() async {
    final PickSubtitleFile? injected = widget.pickSubtitleFile;
    if (injected != null) return injected();
    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: '导入字幕',
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
    if (widget.controller.busy) return;
    final SubtitleFileData? selected = await _pickSubtitleFile();
    if (selected == null) return;
    try {
      final TranscriptionResult result = parseSubtitleText(
        await _readSubtitleFile(selected),
        format: _subtitleFormat(selected),
      );
      widget.controller.applyImportedResult(result);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导入字幕：${selected.name}')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入字幕失败：$error')));
    }
  }

  Future<void> _openProject() async {
    final PickedProjectFile? selected = await _pickProjectFile();
    if (selected == null) return;
    await _openSelectedProject(selected);
  }

  Future<void> _openRecentProject(String path) => _openProjectAt(path);

  Future<void> _openProjectAt(String path) async {
    await _openSelectedProject(
      PickedProjectFile(name: p.basename(path), path: path),
    );
  }

  Future<void> _openSelectedProject(PickedProjectFile selected) async {
    try {
      final VsasrProject project;
      final Uint8List? bytes = selected.bytes;
      if (bytes != null) {
        project = const ProjectFileStore().loadBytes(bytes);
      } else {
        final String? path = selected.path;
        if (path == null) throw const FormatException('项目文件没有可读取的路径');
        final LoadProjectFile load =
            widget.loadProjectFile ?? const ProjectFileStore().load;
        project = await load(path);
      }
      await widget.controller.loadProject(project);
      await _checkProjectMedia();
      final VsasrProject currentProject = widget.controller.projectSnapshot;
      final String? recentPath = await _projectPathForRecent(
        project: currentProject,
        externalPath: selected.path,
        identity: selected.path ?? selected.name,
        refreshCache: currentProject.mediaPath != project.mediaPath,
      );
      if (recentPath != null) await _rememberRecentProject(recentPath);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已打开项目：${selected.name}')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开项目失败：$error')));
    }
  }

  Future<bool> _mediaFileExists(String? path) async {
    if (path == null) return false;
    final String? normalized = _normalizeRecentProjectPath(path);
    if (normalized == null) return false;
    return widget.mediaFileExists?.call(normalized) ??
        File(normalized).exists();
  }

  Future<void> _checkProjectMedia() async {
    if (await _mediaFileExists(widget.controller.filePath)) return;
    if (!mounted) return;
    final bool? relocate = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('媒体文件不存在'),
        content: const Text('项目中的原媒体文件已不可用。你仍可以继续查看和编辑字幕，或重新选择对应的音频/视频文件。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续使用字幕'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重新选择媒体'),
          ),
        ],
      ),
    );
    if (!mounted || relocate != true) return;
    final String? path = await _pickFile();
    if (!mounted || path == null) return;
    final String? normalized = _normalizeRecentProjectPath(path);
    if (normalized == null || !await _mediaFileExists(normalized)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('所选媒体文件不存在，请重新选择')));
      return;
    }
    widget.controller.relocateMedia(normalized);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('媒体文件已重新定位：${p.basename(normalized)}')),
    );
  }

  Future<void> _saveProject() async {
    if (widget.controller.result == null || widget.controller.busy) return;
    try {
      final VsasrProject project = widget.controller.projectSnapshot;
      final String content = const JsonEncoder.withIndent('  ')
          .convert(project.toJson());
      final String? saved = await _saveFile(
        'VoiceSmallASR.vsasr.json',
        '$content\n',
        dialogTitle: '保存 VoiceSmallASR 项目',
      );
      if (saved != null) {
        final String? recentPath = await _projectPathForRecent(
          project: project,
          externalPath: saved,
          identity: saved,
        );
        if (recentPath != null) await _rememberRecentProject(recentPath);
      }
      if (saved != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('项目已保存到 $saved')));
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存项目失败：$error')));
    }
  }

  Future<void> _export({
    required String Function(String format) render,
    required String baseName,
  }) async {
    final String? format = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('导出格式'),
        children: <Widget>[
          for (final String value in kSubtitleFormats)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, value),
              child: Text('${value.toUpperCase()} — ${_formatHints[value]}'),
            ),
        ],
      ),
    );
    if (format == null || !mounted) return;

    final String fileName = '$baseName.$format';
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final String content = render(format);
      final String? saved = await _saveFile(fileName, content);
      if (saved != null) {
        messenger.showSnackBar(SnackBar(content: Text('已导出到 $saved')));
      }
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$error')));
    }
  }

  Future<void> _exportFile() {
    final String source = widget.controller.filePath ?? 'subtitle';
    return _export(
      render: widget.controller.renderResult,
      baseName: p.basenameWithoutExtension(source),
    );
  }

  Future<void> _exportLive() {
    final LiveController? live = widget.live;
    if (live == null) return Future<void>.value();
    return _export(render: live.renderResult, baseName: 'live');
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SettingsPage(
          controller: widget.controller,
          repository: widget.settings ?? AppSettingsRepository(),
        ),
      ),
    );
  }

  Future<void> _openEditor() async {
    final TranscriptionResult? result = widget.controller.result;
    if (result == null || widget.controller.busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SubtitleEditorPage(
          initialResult: result,
          player: widget.video,
          onSave: widget.controller.applyEditedResult,
        ),
      ),
    );
  }

  Future<void> _translate() async {
    final TranscriptionResult? result = widget.controller.result;
    if (result == null || widget.controller.busy) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final AppSettingsRepository repository =
          widget.settings ?? AppSettingsRepository();
      final TranslationApiSettings settings = await repository
          .loadTranslationApiSettings();
      final String? apiKey = await repository.translationSecrets.readApiKey();
      if (!mounted) return;
      if (apiKey == null) {
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
      final TranslationProvider provider =
          widget.translationProviderFactory?.call(apiKey) ??
          ApiTranslationProvider(
            apiKey: apiKey,
            endpoint: settings.endpoint,
            model: settings.model,
          );
      try {
        await widget.controller.translateCurrentResult(
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

  Future<void> _translateBatch() async {
    if (_batch.running || !_batch.hasTranslatableItems) return;
    final AppSettingsRepository repository = _settingsRepository;
    final TranslationApiSettings settings = await repository
        .loadTranslationApiSettings();
    if (!mounted) return;
    if (!_translationDisclosureAccepted) {
      final bool confirmed = await confirmThirdPartyTranslation(context);
      if (!confirmed || !mounted) return;
      _translationDisclosureAccepted = true;
    }

    final TranslationProvider? provider;
    final Future<TranslationProvider?> Function()? resolver =
        widget.translationProviderResolver;
    if (resolver != null) {
      provider = await resolver();
    } else {
      final String? apiKey = await repository.translationSecrets.readApiKey();
      if (apiKey == null) {
        throw StateError('请先在设置中保存第三方翻译 API Key');
      }
      provider =
          widget.translationProviderFactory?.call(apiKey) ??
          ApiTranslationProvider(
            apiKey: apiKey,
            endpoint: settings.endpoint,
            model: settings.model,
          );
    }
    if (provider == null) {
      throw StateError('请先在设置中配置可用的第三方翻译服务');
    }
    try {
      await _batch.translateAll(
        provider,
        targetLanguage: settings.targetLanguage,
      );
    } finally {
      if (provider is ClosableTranslationProvider) provider.close();
    }
  }

  Future<void> _setLiveTranslation(bool enabled) async {
    final LiveController? live = widget.live;
    if (live == null) return;
    if (!enabled || _liveTranslationDisclosureAccepted) {
      live.setTranslationEnabled(enabled);
      return;
    }
    final bool confirmed = await confirmThirdPartyTranslation(context);
    if (!mounted || !confirmed) return;
    _liveTranslationDisclosureAccepted = true;
    live.setTranslationEnabled(true);
  }

  @override
  Widget build(BuildContext context) {
    final LiveController? live = widget.live;
    return ListenableBuilder(
      // 两个控制器都要监听：语言下拉在录音时必须禁用（切语言会重启 isolate）。
      listenable: Listenable.merge(<Listenable>[
        widget.controller,
        _batch,
        ?live,
        ?widget.video,
      ]),
      builder: (BuildContext context, Widget? _) {
        final TranscribeController c = widget.controller;
        final bool batchBusy = _batch.running || _batch.paused;
        final Widget body;
        if (!c.modelReady) {
          body = _ModelSetupView(controller: c);
        } else if (live == null && widget.video == null) {
          body = _TranscribeView(
            controller: c,
            onOpen: _openFile,
            onOpenProject: _openProject,
            recentProjects: _recentProjects,
            onOpenRecentProject: _openRecentProject,
            onSaveProject: _saveProject,
            onExport: _exportFile,
            onEdit: _openEditor,
            onTranslate: _translate,
            onImport: _importSubtitle,
            onBatch: _openBatch,
            batchBusy: batchBusy,
          );
        } else {
          body = _Tabs(
            transcribe: _TranscribeView(
              controller: c,
              onOpen: _openFile,
              onOpenProject: _openProject,
              recentProjects: _recentProjects,
              onOpenRecentProject: _openRecentProject,
              onSaveProject: _saveProject,
              onExport: _exportFile,
              onEdit: _openEditor,
              onTranslate: _translate,
              onImport: _importSubtitle,
              onBatch: _openBatch,
              batchBusy: batchBusy,
            ),
            live: live == null
                ? null
                : _LiveView(
                    controller: live,
                    onExport: _exportLive,
                    onTranslationChanged: (bool enabled) {
                      unawaited(_setLiveTranslation(enabled));
                    },
                  ),
            video: widget.video == null
                ? null
                : VideoPage(
                    controller: widget.video!,
                    transcription: c,
                    settings: widget.settings,
                    translationProviderResolver:
                        widget.translationProviderResolver,
                  ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('VoiceSmallASR'),
            actions: <Widget>[
              _LanguagePicker(controller: c, enabled: !(live?.busy ?? false)),
              IconButton(
                tooltip: '设置',
                onPressed: c.busy || (live?.busy ?? false)
                    ? null
                    : _openSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
              const SizedBox(width: 12),
            ],
          ),
          body: body,
        );
      },
    );
  }

  @override
  void dispose() {
    _detached = true;
    _autosaveTimer?.cancel();
    _batch.dispose();
    widget.controller.removeListener(_onControllerChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_endSessionOnExit());
    super.dispose();
  }
}

/// 「文件转写 / 实时字幕」两个页签。
class _Tabs extends StatelessWidget {
  const _Tabs({required this.transcribe, this.live, this.video});

  final Widget transcribe;
  final Widget? live;
  final Widget? video;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 1 + (live == null ? 0 : 1) + (video == null ? 0 : 1),
      child: Column(
        children: <Widget>[
          TabBar(
            tabs: <Widget>[
              const Tab(icon: Icon(Icons.audio_file_outlined), text: '文件转写'),
              if (live != null)
                const Tab(icon: Icon(Icons.mic_none), text: '实时字幕'),
              if (video != null)
                const Tab(
                  icon: Icon(Icons.video_library_outlined),
                  text: '视频播放',
                ),
            ],
          ),
          Expanded(
            child: TabBarView(children: <Widget>[transcribe, ?live, ?video]),
          ),
        ],
      ),
    );
  }
}

const Map<String, String> _formatHints = <String, String>{
  'srt': '最通用的字幕格式',
  'vtt': '网页播放器用',
  'json': '带 token 级时间戳',
  'txt': '纯文本，不含时间',
};

/// 语言选择。切换会重启识别 isolate（语言在建识别器时就定死了），
/// 因此录音过程中必须禁用 —— 否则会把正在用的会话拆掉。
class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker({required this.controller, this.enabled = true});

  final TranscribeController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<String>(
      value: controller.language,
      underline: const SizedBox.shrink(),
      onChanged: (controller.busy || !enabled)
          ? null
          : (String? value) {
              if (value != null) controller.setLanguage(value);
            },
      items: <DropdownMenuItem<String>>[
        for (final String code in kLanguages)
          DropdownMenuItem<String>(
            value: code,
            child: Text(kLanguageLabels[code] ?? code),
          ),
      ],
    );
  }
}

/// 首次运行的模型准备页。
class _ModelSetupView extends StatelessWidget {
  const _ModelSetupView({required this.controller});

  final TranscribeController controller;

  @override
  Widget build(BuildContext context) {
    final bool working =
        controller.stage == JobStage.preparingModel ||
        controller.stage == JobStage.managingModel;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Icon(Icons.cloud_download_outlined, size: 48),
              const SizedBox(height: 16),
              Text(
                '首次使用需要下载模型',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                '识别模型约 155 MB（解压后 240 MB），另有 630 KB 的断句模型。\n'
                '下载会依次尝试 GitHub 与两个镜像源，任一成功即止；\n'
                '下好之后完全离线可用，不会再联网。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (working) ...<Widget>[
                LinearProgressIndicator(value: controller.progress),
                const SizedBox(height: 8),
                Text(controller.statusText, textAlign: TextAlign.center),
              ] else
                FilledButton.icon(
                  onPressed: controller.downloadModel,
                  icon: const Icon(Icons.download),
                  label: Text(controller.errorText == null ? '下载模型' : '重试'),
                ),
              if (controller.errorText != null) ...<Widget>[
                const SizedBox(height: 16),
                _ErrorBox(message: controller.errorText!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 转写主视图：工具条 + 状态 + 分段列表。
class _TranscribeView extends StatelessWidget {
  const _TranscribeView({
    required this.controller,
    required this.onOpen,
    required this.onOpenProject,
    required this.recentProjects,
    required this.onOpenRecentProject,
    required this.onSaveProject,
    required this.onExport,
    required this.onEdit,
    required this.onTranslate,
    required this.onImport,
    required this.onBatch,
    this.batchBusy = false,
  });

  final TranscribeController controller;
  final VoidCallback onOpen;
  final VoidCallback onOpenProject;
  final List<String> recentProjects;
  final ValueChanged<String> onOpenRecentProject;
  final VoidCallback onSaveProject;
  final VoidCallback onExport;
  final VoidCallback onEdit;
  final VoidCallback onTranslate;
  final VoidCallback onImport;
  final VoidCallback onBatch;
  final bool batchBusy;

  @override
  Widget build(BuildContext context) {
    final TranscriptionResult? result = controller.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FilledButton.icon(
                onPressed: controller.busy || batchBusy ? null : onOpen,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择音频/视频'),
              ),
              OutlinedButton.icon(
                key: const Key('openBatchProcessing'),
                onPressed: controller.busy || batchBusy ? null : onBatch,
                icon: const Icon(Icons.playlist_play),
                label: const Text('批量处理'),
              ),
              PopupMenuButton<String>(
                key: const Key('recentProjects'),
                tooltip: '最近项目',
                onSelected: controller.busy || batchBusy
                    ? null
                    : onOpenRecentProject,
                itemBuilder: (BuildContext context) {
                  if (recentProjects.isEmpty) {
                    return <PopupMenuEntry<String>>[
                      const PopupMenuItem<String>(
                        enabled: false,
                        value: '',
                        child: Text('暂无最近项目'),
                      ),
                    ];
                  }
                  return recentProjects
                      .map(
                        (String path) => PopupMenuItem<String>(
                          value: path,
                          child: Text(
                            p.basename(path),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false);
                },
                icon: const Icon(Icons.history),
              ),
              OutlinedButton.icon(
                onPressed: controller.busy || batchBusy ? null : onOpenProject,
                icon: const Icon(Icons.folder_zip_outlined),
                label: const Text('打开项目'),
              ),
              OutlinedButton.icon(
                onPressed: result == null || controller.busy || batchBusy
                    ? null
                    : onSaveProject,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存项目'),
              ),
              OutlinedButton.icon(
                onPressed: result == null || controller.busy || batchBusy
                    ? null
                    : onExport,
                icon: const Icon(Icons.save_alt),
                label: const Text('导出字幕'),
              ),
              OutlinedButton.icon(
                key: const Key('importSubtitle'),
                onPressed: controller.busy || batchBusy ? null : onImport,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('导入字幕'),
              ),
              OutlinedButton.icon(
                key: const Key('openSubtitleEditor'),
                onPressed: result == null || controller.busy || batchBusy
                    ? null
                    : onEdit,
                icon: const Icon(Icons.edit_note),
                label: const Text('校对字幕'),
              ),
              OutlinedButton.icon(
                key: const Key('translateSubtitle'),
                onPressed: result == null || controller.busy || batchBusy
                    ? null
                    : onTranslate,
                icon: const Icon(Icons.translate),
                label: const Text('翻译为中文'),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  controller.filePath == null
                      ? ''
                      : p.basename(controller.filePath!),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        if (controller.busy)
          LinearProgressIndicator(value: controller.progress),
        if (controller.statusText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(controller.statusText),
          ),
        if (controller.errorText != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: _ErrorBox(message: controller.errorText!),
          ),
        const Divider(height: 1),
        Expanded(
          child: result == null || result.isEmpty
              ? const Center(child: Text('选一个音频或视频文件开始'))
              : _SegmentList(result: result),
        ),
        if (result != null && !result.isEmpty)
          _Footer(controller: controller, result: result),
      ],
    );
  }
}

/// 实时字幕页：录音按钮 + 定稿列表 + 末尾一行临时结果。
class _LiveView extends StatelessWidget {
  const _LiveView({
    required this.controller,
    required this.onExport,
    required this.onTranslationChanged,
  });

  final LiveController controller;
  final VoidCallback onExport;
  final ValueChanged<bool> onTranslationChanged;

  @override
  Widget build(BuildContext context) {
    final bool recording = controller.recording;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FilledButton.icon(
                onPressed: controller.stage == LiveStage.idle
                    ? controller.start
                    : (recording ? controller.stop : null),
                icon: Icon(recording ? Icons.stop : Icons.mic),
                label: Text(recording ? '停止' : '开始录音'),
                style: recording
                    ? FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      )
                    : null,
              ),
              OutlinedButton.icon(
                onPressed: controller.hasResult && !controller.busy
                    ? onExport
                    : null,
                icon: const Icon(Icons.save_alt),
                label: const Text('导出字幕'),
              ),
              OutlinedButton.icon(
                onPressed: controller.hasResult && !controller.busy
                    ? controller.clear
                    : null,
                icon: const Icon(Icons.clear_all),
                label: const Text('清空'),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text('实时翻译'),
                  Switch.adaptive(
                    key: const Key('liveTranslationToggle'),
                    value: controller.translationEnabled,
                    onChanged: onTranslationChanged,
                  ),
                ],
              ),
            ],
          ),
        ),
        // 只在准备/收尾这两个过渡态转圈。录音本身可能持续几十分钟，
        // 一直挂着不定量进度条既没信息量，也会让界面永远处于动画中。
        if (controller.busy && !recording) const LinearProgressIndicator(),
        if (controller.statusText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(controller.statusText),
          ),
        if (controller.errorText != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: _ErrorBox(message: controller.errorText!),
          ),
        const Divider(height: 1),
        Expanded(
          child: controller.finals.isEmpty && controller.partial == null
              ? const Center(child: Text('点「开始录音」，边说边出字幕'))
              : _LiveList(controller: controller),
        ),
      ],
    );
  }
}

/// 定稿句子在上、临时结果在最后一行。
///
/// 临时结果不给序号、用斜体加省略号 —— 它随时会被同一句的定稿结果整行替换，
/// 界面上要一眼看出「这行还没定」。
class _LiveList extends StatelessWidget {
  const _LiveList({required this.controller});

  final LiveController controller;

  @override
  Widget build(BuildContext context) {
    final List<Segment> finals = controller.finals;
    final Segment? partial = controller.partial;
    final ThemeData theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: finals.length + (partial == null ? 0 : 1),
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        if (index >= finals.length) {
          return ListTile(
            dense: true,
            leading: Icon(
              Icons.graphic_eq,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              '${partial!.text} …',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final Segment segment = finals[index];
        return ListTile(
          dense: true,
          leading: Text('${segment.index + 1}'),
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
            '${formatTimestamp(segment.start, sep: '.')} → '
            '${formatTimestamp(segment.end, sep: '.')}',
            style: theme.textTheme.bodySmall,
          ),
          trailing:
              controller.translationEnabled &&
                  controller.canRetryTranslation(segment)
              ? IconButton(
                  key: ValueKey<String>('retryTranslation_${segment.index}'),
                  tooltip: '重试翻译',
                  onPressed: controller.isRetrying(segment)
                      ? null
                      : () => unawaited(controller.retryTranslation(segment)),
                  icon: controller.isRetrying(segment)
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                )
              : null,
        );
      },
    );
  }
}

class _SegmentList extends StatelessWidget {
  const _SegmentList({required this.result});

  final TranscriptionResult result;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: result.length,
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final Segment segment = result.segments[index];
        final String span =
            '${formatTimestamp(segment.start, sep: '.')} → '
            '${formatTimestamp(segment.end, sep: '.')}';
        return ListTile(
          dense: true,
          leading: Text('${segment.index + 1}'),
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
          subtitle: Row(
            children: <Widget>[
              Text(span, style: Theme.of(context).textTheme.bodySmall),
              if (segment.language.isNotEmpty) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  kLanguageLabels[segment.language] ?? segment.language,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.controller, required this.result});

  final TranscribeController controller;
  final TranscriptionResult result;

  @override
  Widget build(BuildContext context) {
    final Duration? elapsed = controller.elapsed;
    final String rtf = elapsed == null || result.duration <= 0
        ? ''
        : '　RTF ${(elapsed.inMilliseconds / 1000 / result.duration).toStringAsFixed(3)}';
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        '${result.length} 段　音频 ${result.duration.toStringAsFixed(2)}s'
        '${elapsed == null ? '' : '　耗时 ${(elapsed.inMilliseconds / 1000).toStringAsFixed(2)}s'}'
        '$rtf',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: colors.onErrorContainer, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
