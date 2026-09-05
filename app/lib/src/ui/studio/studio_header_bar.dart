/// Studio 顶部工作流导航与操作栏。
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/ui/theme/studio_theme.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

class StudioHeaderBar extends StatelessWidget {
  const StudioHeaderBar({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.onOpenProject,
    required this.recentProjects,
    required this.onOpenRecentProject,
    required this.onSaveProject,
    required this.onExport,
    required this.onEdit,
    required this.onTranslate,
    required this.onDiarize,
    required this.onImport,
    required this.onBatch,
    required this.onDiagnostics,
    required this.onHistory,
    required this.historyAvailable,
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
  final VoidCallback onDiarize;
  final VoidCallback onImport;
  final VoidCallback onBatch;
  final VoidCallback onDiagnostics;
  final VoidCallback onHistory;
  final bool historyAvailable;
  final bool batchBusy;

  Widget _buildDivider() {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: StudioColors.border,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TranscriptionResult? result = controller.result;
    final bool disabled = controller.busy || batchBusy;
    final bool hasResult = result != null && !result.isEmpty;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: StudioColors.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 操作工具栏：采用轻量紧凑的流式排布，大屏单行贯通，小屏自然折行且绝不遮挡或溢出
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              // 主要输入操作
              FilledButton.icon(
                onPressed: disabled ? null : onOpen,
                icon: const Icon(Icons.folder_open, size: 14),
                label: const Text('选择音频/视频'),
                style: FilledButton.styleFrom(
                  backgroundColor: StudioColors.primary,
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('openBatchProcessing'),
                onPressed: disabled ? null : onBatch,
                icon: const Icon(Icons.playlist_play, size: 15),
                label: const Text('批量处理'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
              ),
              _buildDivider(),
              // 项目管理组
              OutlinedButton.icon(
                onPressed: disabled ? null : onOpenProject,
                icon: const Icon(Icons.folder_zip_outlined, size: 14),
                label: const Text('打开项目'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: !hasResult || disabled ? null : onSaveProject,
                icon: const Icon(Icons.save_outlined, size: 14),
                label: const Text('保存项目'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                key: const Key('recentProjects'),
                tooltip: '最近项目',
                onSelected: disabled ? null : onOpenRecentProject,
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
                icon: const Icon(Icons.history, size: 16),
              ),
              _buildDivider(),
              // 字幕导入与导出
              OutlinedButton.icon(
                key: const Key('importSubtitle'),
                onPressed: disabled ? null : onImport,
                icon: const Icon(Icons.file_download_outlined, size: 14),
                label: const Text('导入字幕'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: !hasResult || disabled ? null : onExport,
                icon: const Icon(Icons.save_alt, size: 14),
                label: const Text('导出字幕'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
              ),
              if (controller.performanceReport != null)
                OutlinedButton.icon(
                  key: const Key('performanceDiagnostics'),
                  onPressed: disabled ? null : onDiagnostics,
                  icon: const Icon(Icons.speed_outlined, size: 14),
                  label: const Text('性能诊断'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                ),
              if (historyAvailable)
                OutlinedButton.icon(
                  key: const Key('performanceHistory'),
                  onPressed: disabled ? null : onHistory,
                  icon: const Icon(Icons.history_toggle_off, size: 14),
                  label: const Text('性能历史'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                ),
              _buildDivider(),
              // AI 增强与校对组
              OutlinedButton.icon(
                key: const Key('translateSubtitle'),
                onPressed: !hasResult || disabled ? null : onTranslate,
                icon: const Icon(Icons.translate, size: 14),
                label: const Text('翻译为中文'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('autoSpeakerDiarization'),
                onPressed: !hasResult || disabled ? null : onDiarize,
                icon: const Icon(
                  Icons.record_voice_over_outlined,
                  size: 14,
                ),
                label: const Text('自动标注说话人'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('openSubtitleEditor'),
                onPressed: !hasResult || disabled ? null : onEdit,
                icon: const Icon(Icons.edit_note, size: 15),
                label: const Text('校对字幕'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
              ),
              // 当前媒体文件名徽章
              if (controller.filePath != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: StudioColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.movie_creation_outlined,
                        size: 13,
                        color: StudioColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          p.basename(controller.filePath!),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: StudioColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (controller.busy) ...<Widget>[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: controller.progress,
              backgroundColor: StudioColors.surfaceElevated,
              color: StudioColors.primary,
              minHeight: 2,
            ),
          ],
          if (controller.statusText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                controller.statusText,
                style: const TextStyle(
                  fontSize: 11,
                  color: StudioColors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
