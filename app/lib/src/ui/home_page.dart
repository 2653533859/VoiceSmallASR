/// 主页面：模型准备、文件转写与实时字幕两个页签、分段列表、导出字幕。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';
import 'package:vsasr_app/src/ui/live_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

/// 选择要转写的文件，返回绝对路径；用户取消时返回 null。
typedef PickFile = Future<String?> Function();

/// 保存字幕：给文件名与内容，返回落地位置的描述；用户取消时返回 null。
typedef SaveFile = Future<String?> Function(String fileName, String content);

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    this.live,
    this.pickFile,
    this.saveFile,
  });

  final TranscribeController controller;

  /// 实时字幕。为 null 时不显示「实时字幕」页签（不需要麦克风的测试用）。
  final LiveController? live;

  /// 文件选择与保存。测试注入替身，默认走 `file_picker`。
  final PickFile? pickFile;
  final SaveFile? saveFile;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    // build 之后再查模型，避免在 initState 里同步 notifyListeners。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.refreshModel();
    });
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

  Future<String?> _saveFile(String fileName, String content) async {
    final SaveFile? injected = widget.saveFile;
    if (injected != null) return injected(fileName, content);
    // file_picker 12 的 saveFile 自己落盘（Android SAF、macOS sandbox 都由它处理），
    // 因此这里交出字节而不是路径。
    final Uri? saved = await FilePicker.saveFile(
      dialogTitle: '导出字幕',
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

  @override
  Widget build(BuildContext context) {
    final LiveController? live = widget.live;
    return ListenableBuilder(
      // 两个控制器都要监听：语言下拉在录音时必须禁用（切语言会重启 isolate）。
      listenable: live == null
          ? widget.controller
          : Listenable.merge(<Listenable>[widget.controller, live]),
      builder: (BuildContext context, Widget? _) {
        final TranscribeController c = widget.controller;
        final Widget body;
        if (!c.modelReady) {
          body = _ModelSetupView(controller: c);
        } else if (live == null) {
          body = _TranscribeView(controller: c, onOpen: _openFile, onExport: _exportFile);
        } else {
          body = _Tabs(
            transcribe: _TranscribeView(controller: c, onOpen: _openFile, onExport: _exportFile),
            live: _LiveView(controller: live, onExport: _exportLive),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('VoiceSmallASR'),
            actions: <Widget>[
              _LanguagePicker(controller: c, enabled: !(live?.busy ?? false)),
              const SizedBox(width: 12),
            ],
          ),
          body: body,
        );
      },
    );
  }
}
/// 「文件转写 / 实时字幕」两个页签。
class _Tabs extends StatelessWidget {
  const _Tabs({required this.transcribe, required this.live});

  final Widget transcribe;
  final Widget live;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: <Widget>[
          const TabBar(
            tabs: <Widget>[
              Tab(icon: Icon(Icons.audio_file_outlined), text: '文件转写'),
              Tab(icon: Icon(Icons.mic_none), text: '实时字幕'),
            ],
          ),
          Expanded(child: TabBarView(children: <Widget>[transcribe, live])),
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
      onChanged: (controller.busy || !enabled) ? null : (String? value) {
        if (value != null) controller.setLanguage(value);
      },
      items: <DropdownMenuItem<String>>[
        for (final String code in kLanguages)
          DropdownMenuItem<String>(value: code, child: Text(kLanguageLabels[code] ?? code)),
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
    final bool working = controller.stage == JobStage.preparingModel;
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
                  onPressed: controller.prepare,
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
    required this.onExport,
  });

  final TranscribeController controller;
  final VoidCallback onOpen;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final TranscriptionResult? result = controller.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              FilledButton.icon(
                onPressed: controller.busy ? null : onOpen,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择音频/视频'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: result == null || controller.busy ? null : onExport,
                icon: const Icon(Icons.save_alt),
                label: const Text('导出字幕'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  controller.filePath == null ? '' : p.basename(controller.filePath!),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        if (controller.busy) LinearProgressIndicator(value: controller.progress),
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
        if (result != null && !result.isEmpty) _Footer(controller: controller, result: result),
      ],
    );
  }
}

/// 实时字幕页：录音按钮 + 定稿列表 + 末尾一行临时结果。
class _LiveView extends StatelessWidget {
  const _LiveView({required this.controller, required this.onExport});

  final LiveController controller;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final bool recording = controller.recording;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
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
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: controller.hasResult && !controller.busy ? onExport : null,
                icon: const Icon(Icons.save_alt),
                label: const Text('导出字幕'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: controller.hasResult && !controller.busy ? controller.clear : null,
                icon: const Icon(Icons.clear_all),
                label: const Text('清空'),
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
      separatorBuilder: (BuildContext context, int index) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        if (index >= finals.length) {
          return ListTile(
            dense: true,
            leading: Icon(Icons.graphic_eq, size: 18, color: theme.colorScheme.primary),
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
          title: Text(segment.text),
          subtitle: Text(
            '${formatTimestamp(segment.start, sep: '.')} → '
            '${formatTimestamp(segment.end, sep: '.')}',
            style: theme.textTheme.bodySmall,
          ),
        );
      },
    );
  }
}

class _SegmentList extends StatelessWidget {  const _SegmentList({required this.result});

  final TranscriptionResult result;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: result.length,
      separatorBuilder: (BuildContext context, int index) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final Segment segment = result.segments[index];
        final String span =
            '${formatTimestamp(segment.start, sep: '.')} → '
            '${formatTimestamp(segment.end, sep: '.')}';
        return ListTile(
          dense: true,
          leading: Text('${segment.index + 1}'),
          title: Text(segment.text),
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
          Expanded(child: Text(message, style: TextStyle(color: colors.onErrorContainer))),
        ],
      ),
    );
  }
}
