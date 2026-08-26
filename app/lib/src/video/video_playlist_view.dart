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
    return SizedBox(
      height: 104,
      child: ReorderableListView.builder(
        key: const Key('videoPlaylist'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        scrollDirection: Axis.horizontal,
        itemCount: paths.length,
        buildDefaultDragHandles: false,
        onReorderItem: onReorder,
        itemBuilder: (BuildContext context, int index) {
          final String path = paths[index];
          final bool selected = index == currentIndex;
          final String status = statuses[path] ?? '等待播放';
          final bool canCancel =
              processingPath == path ||
              status.contains('转写中') ||
              status.contains('预转写中');
          return SizedBox(
            key: ValueKey<String>('videoPlaylistItem-$path'),
            width: 230,
            child: Card(
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
                    const SizedBox(width: 4),
                    Text('${index + 1}'),
                  ],
                ),
                title: Text(
                  p.basename(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                            child: Text('取消转写'),
                          ),
                        const PopupMenuItem<String>(
                          key: Key('videoPlaylistRetry'),
                          value: 'retry',
                          child: Text('重试转写'),
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
    );
  }
}
