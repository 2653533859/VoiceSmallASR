/// 播放列表的展示组件。
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class VideoPlaylistView extends StatelessWidget {
  const VideoPlaylistView({
    super.key,
    required this.paths,
    required this.currentIndex,
    required this.statuses,
    required this.processingPath,
    required this.onOpen,
    required this.onReorder,
    required this.onCancel,
    required this.onRetry,
    required this.onDelete,
  });

  final List<String> paths;
  final int currentIndex;
  final Map<String, String> statuses;
  final String? processingPath;
  final ValueChanged<int> onOpen;
  final void Function(int oldIndex, int newIndex) onReorder;
  final ValueChanged<int> onCancel;
  final ValueChanged<int> onRetry;
  final ValueChanged<int> onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.playlist_play),
                const SizedBox(width: 8),
                Text('播放列表', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('${paths.length} 个视频'),
              ],
            ),
          ),
          if (paths.isEmpty)
            const Expanded(child: Center(child: Text('添加视频或选择文件夹')))
          else
            Expanded(
              child: ReorderableListView.builder(
                key: const Key('videoPlaylist'),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                scrollDirection: Axis.vertical,
                itemCount: paths.length,
                buildDefaultDragHandles: false,
                onReorderItem: onReorder,
                itemBuilder: (BuildContext context, int index) {
                  final String path = paths[index];
                  final bool selected = index == currentIndex;
                  final String status = statuses[path] ?? '等待播放';
                  final _PlaylistStatusVisual statusVisual = _statusVisual(
                    status,
                    Theme.of(context).colorScheme,
                  );
                  final bool canCancel =
                      processingPath == path ||
                      status.contains('转写中') ||
                      status.contains('预转写中');
                  return SizedBox(
                    key: ValueKey<String>('videoPlaylistItem-$path'),
                    child: Card(
                      elevation: 0,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: selected
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : null,
                      child: ListTile(
                        dense: true,
                        selected: selected,
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_handle, size: 20),
                            ),
                            const SizedBox(width: 6),
                            if (selected)
                              const Icon(Icons.play_arrow_rounded, size: 18)
                            else
                              Text('${index + 1}'.padLeft(2, '0')),
                          ],
                        ),
                        title: Tooltip(
                          message: p.basename(path),
                          child: Text(
                            p.basename(path),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        subtitle: Row(
                          children: [
                            Icon(
                              statusVisual.icon,
                              size: 14,
                              color: statusVisual.color,
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: statusVisual.color),
                              ),
                            ),
                          ],
                        ),
                        trailing: PopupMenuButton<String>(
                          key: Key('videoPlaylistActions-$index'),
                          tooltip: '播放列表操作',
                          onSelected: (String action) {
                            final int currentIndex = paths.indexOf(path);
                            if (currentIndex < 0) return;
                            if (action == 'cancel') {
                              onCancel(currentIndex);
                            } else if (action == 'retry') {
                              onRetry(currentIndex);
                            } else if (action == 'delete') {
                              onDelete(currentIndex);
                            }
                          },
                          itemBuilder: (BuildContext context) =>
                              <PopupMenuEntry<String>>[
                                if (canCancel)
                                  const PopupMenuItem<String>(
                                    key: Key('videoPlaylistCancel'),
                                    value: 'cancel',
                                    child: Text('取消字幕处理'),
                                  ),
                                const PopupMenuItem<String>(
                                  key: Key('videoPlaylistRetry'),
                                  value: 'retry',
                                  child: Text('重新处理字幕'),
                                ),
                                const PopupMenuItem<String>(
                                  key: Key('videoPlaylistDelete'),
                                  value: 'delete',
                                  child: Text('从播放列表移除'),
                                ),
                              ],
                        ),
                        onTap: () => onOpen(index),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  _PlaylistStatusVisual _statusVisual(String status, ColorScheme colors) {
    if (status.contains('失败') || status.contains('错误')) {
      return _PlaylistStatusVisual(Icons.error_outline, colors.error);
    }
    if (status.contains('转写中') ||
        status.contains('处理') ||
        status.contains('翻译中')) {
      return _PlaylistStatusVisual(Icons.sync, colors.primary);
    }
    if (status.contains('同名') || status.contains('外部')) {
      return _PlaylistStatusVisual(Icons.description_outlined, colors.primary);
    }
    if (status.contains('自动识别')) {
      return _PlaylistStatusVisual(Icons.graphic_eq, colors.primary);
    }
    if (status.contains('缓存')) {
      return _PlaylistStatusVisual(Icons.storage_outlined, colors.tertiary);
    }
    if (status.contains('就绪')) {
      return _PlaylistStatusVisual(Icons.check_circle_outline, colors.primary);
    }
    if (status.contains('未找到')) {
      return _PlaylistStatusVisual(Icons.info_outline, colors.secondary);
    }
    return _PlaylistStatusVisual(
      Icons.subtitles_off_outlined,
      colors.onSurfaceVariant,
    );
  }
}

class _PlaylistStatusVisual {
  const _PlaylistStatusVisual(this.icon, this.color);

  final IconData icon;
  final Color color;
}
