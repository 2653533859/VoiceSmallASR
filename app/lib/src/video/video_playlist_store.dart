/// 视频播放列表的本地持久化。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String kVideoPlaylistSchema = 'voicesmallasr.video_playlist';
const int kVideoPlaylistVersion = 1;
const int kMaxVideoPlaylistEntries = 100;

/// 只保存媒体路径，不复制视频文件，也不保存字幕结果。
class VideoPlaylistStore {
  VideoPlaylistStore({this.rootDirectory});

  final Directory? rootDirectory;

  Future<File> _file() async {
    final Directory support =
        rootDirectory ?? await getApplicationSupportDirectory();
    await support.create(recursive: true);
    return File(p.join(support.path, 'video_playlist.json'));
  }

  Future<List<String>> read() async {
    final File file = await _file();
    if (!await file.exists()) return <String>[];
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != kVideoPlaylistSchema ||
          decoded['version'] != kVideoPlaylistVersion ||
          decoded['paths'] is! List<dynamic>) {
        return <String>[];
      }
      final Set<String> seen = <String>{};
      return (decoded['paths'] as List<dynamic>)
          .whereType<String>()
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty && seen.add(value))
          .take(kMaxVideoPlaylistEntries)
          .toList(growable: false);
    } on Object {
      // 播放列表属于辅助状态；损坏时从空列表开始，不阻塞视频页。
      return <String>[];
    }
  }

  /// 串行化写入，避免快速拖拽或连续添加时较早的异步写覆盖新顺序。
  Future<void> write(List<String> paths) {
    final List<String> snapshot = <String>[];
    final Set<String> seen = <String>{};
    for (final String raw in paths) {
      final String path = raw.trim();
      if (path.isNotEmpty && seen.add(path)) {
        snapshot.add(path);
        if (snapshot.length == kMaxVideoPlaylistEntries) break;
      }
    }
    _writeQueue = _writeQueue
        .catchError((Object _) {})
        .then<void>((_) => _writeSnapshot(snapshot));
    return _writeQueue;
  }

  Future<void> _writeSnapshot(List<String> paths) async {
    final File file = await _file();
    final File temporary = File('${file.path}.tmp');
    final String content = const JsonEncoder.withIndent('  ')
        .convert(<String, Object?>{
          'schema': kVideoPlaylistSchema,
          'version': kVideoPlaylistVersion,
          'paths': paths,
        });
    await temporary.writeAsString('$content\n', flush: true);
    await temporary.rename(file.path);
  }

  Future<void> _writeQueue = Future<void>.value();
}
