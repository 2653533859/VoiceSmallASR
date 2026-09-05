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
import 'package:vsasr_app/src/diagnostics/performance_log_store.dart';
import 'package:vsasr_app/src/diagnostics/performance_report.dart';
import 'package:vsasr_app/src/project/project_file.dart';
import 'package:vsasr_app/src/project/batch_translation_cache.dart';
import 'package:vsasr_app/src/ui/batch_queue_store.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/settings/settings_page.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_page.dart';
import 'package:vsasr_app/src/ui/live_controller.dart';
import 'package:vsasr_app/src/ui/batch_page.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';
import 'package:vsasr_app/src/ui/home_export_coordinator.dart';
import 'package:vsasr_app/src/ui/home_workflow_coordinator.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/ui/video_page.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/translation/translation_disclosure.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/ui/studio/studio_workspace.dart';
import 'package:vsasr_app/src/ui/theme/studio_theme.dart';
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
    this.batchTranslationCache,
    this.batchQueueStore,
    this.performanceLogStore,
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

  /// 翻译缓存。测试可注入临时目录；生产环境默认使用应用私有支持目录。
  final BatchTranslationCache? batchTranslationCache;

  /// 批量队列恢复存储。测试可注入内存或临时目录实现。
  final BatchQueueStore? batchQueueStore;

  /// 性能历史存储。测试可注入临时目录；生产环境默认使用应用支持目录。
  final PerformanceLogStore? performanceLogStore;

  final MediaFileExists? mediaFileExists;

  /// 设置存储。测试注入替身；生产环境由顶层应用复用同一个仓库。
  final AppSettingsRepository? settings;

  final TranslationProviderFactory? translationProviderFactory;
  final Future<TranslationProvider?> Function()? translationProviderResolver;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final HomeWorkflowCoordinator _workflow;
  final HomeExportCoordinator _exporter = HomeExportCoordinator();
  bool _translationDisclosureAccepted = false;
  bool _liveTranslationDisclosureAccepted = false;
  late final VideoPlaybackController _video =
      widget.video ??
      VideoPlaybackController(backend: const _StubVideoPlayerBackend());
  late final bool _ownsVideo = widget.video == null;

  AppSettingsRepository get _settingsRepository =>
      widget.settings ?? AppSettingsRepository();

  BatchTranslationCache get _batchTranslationCache =>
      widget.batchTranslationCache ?? const BatchTranslationCache();

  @override
  void initState() {
    super.initState();
    _workflow = HomeWorkflowCoordinator(
      controller: widget.controller,
      live: widget.live,
      settings: widget.settings,
      autosave: widget.autosaveStore ?? const FileProjectAutosaveStore(),
      batchQueue: widget.batchQueueStore ?? const BatchQueueStore(),
      performanceLog: widget.performanceLogStore ?? PerformanceLogStore(),
      onError: _showWorkflowError,
    )..init();
    // build 之后再查模型，避免在 initState 里同步 notifyListeners。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.refreshModel();
      unawaited(_workflow.loadRecentProjects());
      unawaited(
        _workflow.loadRecovery(
          onProjectRecovery: _showProjectRecoveryPrompt,
          onBatchRecovery: _showBatchRecoveryPrompt,
        ),
      );
    });
  }

  void _showWorkflowError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool?> _showBatchRecoveryPrompt(
    BatchQueueSnapshot snapshot,
    int pendingCount,
  ) {
    if (!mounted) return Future<bool?>.value();
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('发现未完成的批量任务'),
        content: Text('检测到上次退出前仍有 $pendingCount 个批量条目未完成，是否恢复任务？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('放弃任务'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复任务'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showProjectRecoveryPrompt(VsasrProject project) async {
    if (!mounted) return null;
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
    if (!mounted || recover != true) return recover;
    try {
      await widget.controller.loadProject(project);
      await _checkProjectMedia();
      if (!mounted) return null;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已恢复上次自动保存的项目')));
      return true;
    } on Object catch (error) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('恢复项目失败：$error')));
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
          controller: _workflow.batch,
          pickFiles: _pickBatchFiles,
          onTranslate: _translateBatch,
          onExport: _exportBatch,
          onDiagnostics: _showBatchPerformanceReport,
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
      final String? recentPath = await _workflow.projectPathForRecent(
        project: currentProject,
        externalPath: selected.path,
        identity: selected.path ?? selected.name,
        refreshCache: currentProject.mediaPath != project.mediaPath,
      );
      if (recentPath != null) {
        await _workflow.rememberRecentProject(recentPath);
      }
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
    final String? normalized = _workflow.normalizeRecentProjectPath(path);
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
    final String? normalized = _workflow.normalizeRecentProjectPath(path);
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
        final String? recentPath = await _workflow.projectPathForRecent(
          project: project,
          externalPath: saved,
          identity: saved,
        );
        if (recentPath != null) {
          await _workflow.rememberRecentProject(recentPath);
        }
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

  Future<void> _showPerformanceReport() async {
    final PerformanceReport? report = widget.controller.performanceReport;
    if (report == null || !mounted) return;
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('性能诊断报告'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(report.toText())),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            key: const Key('exportPerformanceReport'),
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('导出 JSON'),
          ),
        ],
      ),
    );
    if (action != 'save' || !mounted) return;
    final String source = widget.controller.filePath ?? 'transcription';
    final String fileName =
        '${p.basenameWithoutExtension(source)}.performance.json';
    try {
      final String? saved = await _saveFile(
        fileName,
        report.toJsonString(),
        dialogTitle: '导出性能诊断报告',
      );
      if (!mounted || saved == null) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('诊断报告已导出到 $saved')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出诊断报告失败：$error')));
    }
  }

  Future<void> _showBatchPerformanceReport() async {
    final BatchPerformanceReport? report = _workflow.batch.performanceReport;
    if (report == null || !mounted) return;
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('批量性能汇总'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(report.toText())),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            key: const Key('exportBatchPerformanceReport'),
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('导出 JSON'),
          ),
        ],
      ),
    );
    if (action != 'save' || !mounted) return;
    try {
      final String? saved = await _saveFile(
        'batch.performance.json',
        report.toJsonString(),
        dialogTitle: '导出批量性能汇总',
      );
      if (!mounted || saved == null) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('批量性能汇总已导出到 $saved')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出批量性能汇总失败：$error')));
    }
  }

  Future<void> _showLivePerformanceReport() async {
    final LivePerformanceReport? report = widget.live?.performanceReport;
    if (report == null || !mounted) return;
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('实时性能报告'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(report.toText())),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            key: const Key('exportLivePerformanceReport'),
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('导出 JSON'),
          ),
        ],
      ),
    );
    if (action != 'save' || !mounted) return;
    try {
      final String? saved = await _saveFile(
        'live.performance.json',
        report.toJsonString(),
        dialogTitle: '导出实时性能报告',
      );
      if (!mounted || saved == null) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('实时性能报告已导出到 $saved')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出实时性能报告失败：$error')));
    }
  }

  Future<void> _showPerformanceHistory() async {
    if (!mounted) return;
    final Object? selected = await showDialog<Object?>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('性能历史'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: _workflow.performanceHistory.isEmpty
              ? const Center(child: Text('暂无性能历史记录'))
              : ListView.separated(
                  itemCount: _workflow.performanceHistory.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) {
                    final PerformanceLogEntry entry =
                        _workflow.performanceHistory[index];
                    return ListTile(
                      title: Text(entry.label),
                      subtitle: Text(entry.generatedAt.toLocal().toString()),
                      onTap: () => Navigator.of(context).pop(entry),
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('clearPerformanceHistory'),
            onPressed: _workflow.performanceHistory.isEmpty
                ? null
                : () => Navigator.of(context).pop('clear'),
            child: const Text('清空历史'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (selected == 'clear') {
      try {
        await _workflow.clearPerformanceHistory();
        if (!mounted) return;
      } on Object catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清空性能历史失败：$error')));
      }
      return;
    }
    if (selected is! PerformanceLogEntry || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('${selected.label}性能报告'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(selected.report),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportBatch(String format) async {
    final HomeBatchExportSummary summary = await _exporter.exportBatch(
      items: _workflow.batch.items,
      format: format,
      saveFile: _saveFile,
    );
    if (!mounted) return;
    final String message;
    if (summary.cancelled) {
      message =
          '已导出 ${summary.exportedCount}/${summary.totalCount} 个文件，已取消剩余导出';
    } else if (summary.failedCount > 0) {
      message =
          '批量导出完成：成功 ${summary.exportedCount} 个，失败 ${summary.failedCount} 个：${summary.lastError}';
    } else {
      message = '已批量导出 ${summary.exportedCount} 个文件';
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
            glossary: settings.glossary,
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

  /// 为 Studio 单句翻译按需创建 provider。
  ///
  /// 顶层应用通常会注入共享 resolver；直接挂载 [HomePage] 的测试和嵌入场景则
  /// 沿用文件翻译相同的设置与 provider 工厂。
  Future<TranslationProvider?> _resolveStudioTranslationProvider() async {
    final Future<TranslationProvider?> Function()? resolver =
        widget.translationProviderResolver;
    if (resolver != null) return resolver();
    final AppSettingsRepository repository = _settingsRepository;
    final String? apiKey = await repository.translationSecrets.readApiKey();
    if (apiKey == null) return null;
    final TranslationApiSettings settings = await repository
        .loadTranslationApiSettings();
    return widget.translationProviderFactory?.call(apiKey) ??
        ApiTranslationProvider(
          apiKey: apiKey,
          endpoint: settings.endpoint,
          model: settings.model,
          glossary: settings.glossary,
        );
  }

  Future<void> _diarize() async {
    final TranscriptionResult? result = widget.controller.result;
    if (result == null || widget.controller.busy) return;
    final String? input = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        String value = '';
        return AlertDialog(
          title: const Text('自动标注说话人'),
          content: TextField(
            key: const Key('speakerCountInput'),
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '说话人数（可选）',
              hintText: '留空：自动判断人数',
            ),
            onChanged: (String next) => value = next,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(value.trim()),
              child: const Text('开始分析'),
            ),
          ],
        );
      },
    );
    if (!mounted || input == null) return;

    final String countText = input.trim();
    final int? count = countText.isEmpty ? null : int.tryParse(countText);
    if (countText.isNotEmpty && (count == null || count <= 0)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('说话人数必须是正整数，或留空自动判断')));
      return;
    }
    try {
      await widget.controller.diarizeCurrentResult(numClusters: count ?? -1);
      if (!mounted) return;
      final String? error = widget.controller.errorText;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error == null ? '说话人标注完成' : '说话人标注失败：$error')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('说话人标注失败：$error')));
    }
  }

  Future<void> _translateBatch() async {
    if (_workflow.batch.running || !_workflow.batch.hasTranslatableItems) {
      return;
    }
    final AppSettingsRepository repository = _settingsRepository;
    final TranslationApiSettings settings = await repository
        .loadTranslationApiSettings();
    if (!mounted) return;

    final String providerScope = _batchProviderScope(settings);
    final Map<int, TranscriptionResult> cached =
        await _readBatchTranslationCache(
          targetLanguage: settings.targetLanguage,
          providerScope: providerScope,
        );
    if (!mounted) return;
    if (cached.isNotEmpty) {
      final bool? reuse = await _confirmBatchTranslationCache(cached.length);
      if (!mounted || reuse == null) return;
      if (reuse) {
        int applied = 0;
        for (final MapEntry<int, TranscriptionResult> entry in cached.entries) {
          try {
            _workflow.batch.applyCachedTranslation(entry.key, entry.value);
            applied++;
          } on Object {
            // 页面状态可能在异步确认期间发生变化，单个缓存失效按未命中处理。
          }
        }
        if (!_workflow.batch.hasTranslatableItems) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已复用 $applied 个本地翻译缓存')));
          return;
        }
      }
    }
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
            glossary: settings.glossary,
          );
    }
    if (provider == null) {
      throw StateError('请先在设置中配置可用的第三方翻译服务');
    }
    try {
      await _workflow.batch.translateAll(
        provider,
        targetLanguage: settings.targetLanguage,
        onItemTranslated: (BatchItem item) async {
          final TranscriptionResult? result = item.result;
          if (result == null) return;
          await _batchTranslationCache.write(
            mediaPath: item.path,
            translated: result,
            targetLanguage: settings.targetLanguage,
            providerScope: providerScope,
          );
        },
      );
    } finally {
      if (provider is ClosableTranslationProvider) provider.close();
    }
  }

  String _batchProviderScope(TranslationApiSettings settings) {
    // 不把 API Key 写入缓存；术语表变化也必须使旧翻译缓存失效。
    return '${settings.endpoint.trim()}\n${settings.model.trim()}\n${settings.glossary.trim()}';
  }

  Future<Map<int, TranscriptionResult>> _readBatchTranslationCache({
    required String targetLanguage,
    required String providerScope,
  }) async {
    final Map<int, TranscriptionResult> cached = <int, TranscriptionResult>{};
    for (int index = 0; index < _workflow.batch.items.length; index++) {
      final BatchItem item = _workflow.batch.items[index];
      if ((item.status != BatchItemStatus.completed &&
              item.status != BatchItemStatus.translationFailed) ||
          item.result == null) {
        continue;
      }
      try {
        final TranscriptionResult? result = await _batchTranslationCache.read(
          mediaPath: item.path,
          source: item.result!,
          targetLanguage: targetLanguage,
          providerScope: providerScope,
        );
        if (result != null) cached[index] = result;
      } on Object {
        // 缓存读取失败按未命中处理，不影响在线翻译。
      }
    }
    return cached;
  }

  Future<bool?> _confirmBatchTranslationCache(int count) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('发现本地翻译缓存'),
        content: Text('发现 $count 个与当前识别结果匹配的本地翻译缓存，是否复用？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('重新翻译'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('复用缓存'),
          ),
        ],
      ),
    );
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
        _workflow,
        ?live,
        _video,
      ]),
      builder: (BuildContext context, Widget? _) {
        final TranscribeController c = widget.controller;
        final bool batchBusy = _workflow.batchBusy;
        final Widget studio = StudioWorkspace(
          controller: c,
          videoController: _video,
          onOpen: _openFile,
          onOpenProject: _openProject,
          recentProjects: _workflow.recentProjects,
          onOpenRecentProject: _openRecentProject,
          onSaveProject: _saveProject,
          onExport: _exportFile,
          onEdit: _openEditor,
          onTranslate: _translate,
          onDiarize: _diarize,
          onImport: _importSubtitle,
          onBatch: _openBatch,
          onDiagnostics: _showPerformanceReport,
          onHistory: _showPerformanceHistory,
          historyAvailable: _workflow.hasPerformanceHistory,
          batchBusy: batchBusy,
          settings: widget.settings,
          translationProviderResolver: _resolveStudioTranslationProvider,
        );

        final Widget body;
        if (!c.modelReady) {
          body = _ModelSetupView(controller: c);
        } else if (live == null && widget.video == null) {
          body = studio;
        } else {
          body = _Tabs(
            transcribe: studio,
            live: live == null
                ? null
                : _LiveView(
                    controller: live,
                    onExport: _exportLive,
                    onDiagnostics: _showLivePerformanceReport,
                    onHistory: _showPerformanceHistory,
                    historyAvailable: _workflow.hasPerformanceHistory,
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
          backgroundColor: StudioColors.background,
          appBar: AppBar(
            toolbarHeight: 46,
            titleSpacing: 16,
            backgroundColor: StudioColors.surface,
            elevation: 0,
            scrolledUnderElevation: 0,
            shape: const Border(
              bottom: BorderSide(color: StudioColors.border, width: 1),
            ),
            title: Row(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: StudioColors.primarySubtle,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(
                    Icons.graphic_eq_rounded,
                    size: 18,
                    color: StudioColors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'VoiceSmallASR Studio',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: StudioColors.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              _LanguagePicker(controller: c, enabled: !(live?.busy ?? false)),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '设置',
                onPressed: c.busy || (live?.busy ?? false)
                    ? null
                    : _openSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                style: IconButton.styleFrom(
                  foregroundColor: StudioColors.textSecondary,
                  padding: const EdgeInsets.all(8),
                ),
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
    if (_ownsVideo) _video.dispose();
    _workflow.dispose();
    super.dispose();
  }
}

class _StubVideoPlayerBackend implements VideoPlayerBackend {
  const _StubVideoPlayerBackend();

  @override
  Widget buildVideo({VideoOverlayBuilder? overlayBuilder}) =>
      const SizedBox.expand();

  @override
  Stream<Duration> get position => const Stream<Duration>.empty();

  @override
  Stream<Duration> get duration => const Stream<Duration>.empty();

  @override
  Stream<bool> get playing => const Stream<bool>.empty();

  @override
  Future<void> open(String path) async {}

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> dispose() async {}
}

/// 「文件转写 / 实时字幕 / 视频播放」页签，采用紧凑现代的桌面 Studio 标签条。
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
          Container(
            height: 38,
            decoration: const BoxDecoration(
              color: StudioColors.surface,
              border: Border(
                bottom: BorderSide(color: StudioColors.border, width: 1),
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    indicatorSize: TabBarIndicatorSize.label,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 16),
                    indicatorColor: StudioColors.primary,
                    indicatorWeight: 2,
                    labelColor: StudioColors.primary,
                    unselectedLabelColor: StudioColors.textSecondary,
                    dividerColor: Colors.transparent,
                    tabs: <Widget>[
                      const Tab(
                        height: 36,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.audio_file_outlined, size: 15),
                            SizedBox(width: 6),
                            Text('文件转写', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      if (live != null)
                        const Tab(
                          height: 36,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(Icons.mic_none, size: 15),
                              SizedBox(width: 6),
                              Text('实时字幕', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      if (video != null)
                        const Tab(
                          height: 36,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(Icons.video_library_outlined, size: 15),
                              SizedBox(width: 6),
                              Text('视频播放', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
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
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: StudioColors.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: StudioColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: controller.language,
          isDense: true,
          icon: const Icon(
            Icons.arrow_drop_down,
            size: 18,
            color: StudioColors.textSecondary,
          ),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: StudioColors.textPrimary,
          ),
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
        ),
      ),
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




/// 实时字幕页：录音按钮 + 定稿列表 + 末尾一行临时结果。
class _LiveView extends StatelessWidget {
  const _LiveView({
    required this.controller,
    required this.onExport,
    required this.onDiagnostics,
    required this.onHistory,
    required this.historyAvailable,
    required this.onTranslationChanged,
  });

  final LiveController controller;
  final VoidCallback onExport;
  final VoidCallback onDiagnostics;
  final VoidCallback onHistory;
  final bool historyAvailable;
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
              if (controller.performanceReport != null)
                OutlinedButton.icon(
                  key: const Key('livePerformanceDiagnostics'),
                  onPressed: controller.busy ? null : onDiagnostics,
                  icon: const Icon(Icons.speed_outlined),
                  label: const Text('性能诊断'),
                ),
              if (historyAvailable)
                OutlinedButton.icon(
                  key: const Key('livePerformanceHistory'),
                  onPressed: controller.busy ? null : onHistory,
                  icon: const Icon(Icons.history_toggle_off),
                  label: const Text('性能历史'),
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
              if ((segment.speaker ?? '').trim().isNotEmpty)
                Text(
                  '【${segment.speaker!.trim()}】',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
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
