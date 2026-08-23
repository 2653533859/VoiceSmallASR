import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/video/video_subtitle_cache.dart';

void main() {
  late Directory root;
  late File video;
  late VideoSubtitleCache cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('vsasr_video_subtitle_cache');
    video = File(p.join(root.path, '示例 视频.mp4'))..writeAsStringSync('video');
    cache = VideoSubtitleCache(rootDirectory: root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('缓存会保存结构化结果和可直接使用的 SRT', () async {
    const TranscriptionResult result = TranscriptionResult(
      segments: <Segment>[
        Segment(
          text: 'hello',
          translation: '你好',
          start: 0,
          end: 1,
          language: 'en',
          index: 0,
        ),
      ],
      duration: 1,
      language: 'en',
    );

    final String srtPath = await cache.write(video.path, result);

    expect(await cache.read(video.path), isNotNull);
    expect(File(srtPath).readAsStringSync(), contains('你好'));
    expect(p.dirname(srtPath), endsWith(kVideoSubtitleCacheDirectoryName));
  });

  test('视频内容变化后不会复用过期字幕', () async {
    const TranscriptionResult result = TranscriptionResult(
      segments: <Segment>[Segment(text: '字幕', start: 0, end: 1, index: 0)],
      duration: 1,
    );
    await cache.write(video.path, result);

    await Future<void>.delayed(const Duration(milliseconds: 2));
    video.writeAsStringSync('changed video content');

    expect(await cache.read(video.path), isNull);
  });

  test('识别或翻译配置变化后不会复用过期字幕', () async {
    const TranscriptionResult result = TranscriptionResult(
      segments: <Segment>[Segment(text: 'hello', start: 0, end: 1, index: 0)],
      duration: 1,
    );
    await cache.write(video.path, result, configurationScope: 'en-to-zh');

    expect(
      await cache.read(video.path, configurationScope: 'en-to-zh'),
      isNotNull,
    );
    expect(
      await cache.read(video.path, configurationScope: 'ja-to-zh'),
      isNull,
    );
  });
}
