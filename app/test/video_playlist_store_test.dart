import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/video/video_playlist_store.dart';

void main() {
  late Directory root;
  late VideoPlaylistStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('vsasr_video_playlist');
    store = VideoPlaylistStore(rootDirectory: root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('播放列表按顺序持久化并去重', () async {
    await store.write(<String>[
      ' /tmp/one.mp4 ',
      '/tmp/two.mp4',
      '/tmp/one.mp4',
    ]);

    expect(await store.read(), <String>['/tmp/one.mp4', '/tmp/two.mp4']);
    final Map<String, dynamic> document = jsonDecode(
      File(p.join(root.path, 'video_playlist.json')).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(document['schema'], kVideoPlaylistSchema);
    expect(document['version'], kVideoPlaylistVersion);
  });

  test('损坏的播放列表回退为空列表', () async {
    File(p.join(root.path, 'video_playlist.json'))
      ..writeAsStringSync('{bad json')
      ..setLastModifiedSync(DateTime.now());

    expect(await store.read(), isEmpty);
  });
}
