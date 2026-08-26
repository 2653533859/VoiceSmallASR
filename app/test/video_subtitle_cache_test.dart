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

  test('未完成字幕检查点可以恢复，并在完成缓存后清理', () async {
    const TranscriptionResult partial = TranscriptionResult(
      segments: <Segment>[Segment(text: '前半句', start: 0, end: 1, index: 0)],
      duration: 30,
      language: 'zh',
    );

    await cache.writeCheckpoint(
      video.path,
      partial,
      processedSamples: 30 * 16000,
      configurationScope: 'zh',
    );
    final VideoSubtitleCheckpoint? checkpoint = await cache.readCheckpoint(
      video.path,
      configurationScope: 'zh',
    );
    expect(checkpoint, isNotNull);
    expect(checkpoint!.processedSamples, 30 * 16000);
    expect(checkpoint.result.segments.single.text, '前半句');

    await cache.write(video.path, partial, configurationScope: 'zh');
    expect(
      await cache.readCheckpoint(video.path, configurationScope: 'zh'),
      isNull,
    );
  });

  test('只有检查点时也会被统计和清理', () async {
    const TranscriptionResult partial = TranscriptionResult(
      segments: <Segment>[Segment(text: '前半句', start: 0, end: 1, index: 0)],
      duration: 30,
    );
    await cache.writeCheckpoint(
      video.path,
      partial,
      processedSamples: 30 * 16000,
    );

    final VideoSubtitleCacheSummary summary = await cache.inspect();
    expect(summary.entries, hasLength(1));
    expect(summary.entries.single.isComplete, isFalse);
    expect(summary.bytes, greaterThan(0));

    await cache.clearAll();
    expect((await cache.inspect()).entries, isEmpty);
    expect(await cache.readCheckpoint(video.path), isNull);
  });

  test('可以统计、删除缓存，并保护当前媒体', () async {
    const TranscriptionResult result = TranscriptionResult(
      segments: <Segment>[Segment(text: '字幕', start: 0, end: 1, index: 0)],
      duration: 1,
    );
    final File secondVideo = File(p.join(root.path, 'second.mp4'))
      ..writeAsStringSync('second');
    await cache.write(video.path, result);
    await cache.write(secondVideo.path, result);

    final VideoSubtitleCacheSummary summary = await cache.inspect();
    expect(summary.entries, hasLength(2));
    expect(summary.bytes, greaterThan(0));

    final VideoSubtitleCacheCleanupReport protected = await cache.deleteMedia(
      video.path,
      protectedMediaPaths: <String>{video.path},
    );
    expect(protected.skippedEntries, 1);
    expect(await cache.read(video.path), isNotNull);

    final VideoSubtitleCacheCleanupReport deleted = await cache.deleteMedia(
      secondVideo.path,
    );
    expect(deleted.removedEntries, 1);
    expect(await cache.read(secondVideo.path), isNull);
  });

  test('缓存清单会标出视频或配置已变化', () async {
    const TranscriptionResult result = TranscriptionResult(
      segments: <Segment>[Segment(text: '字幕', start: 0, end: 1, index: 0)],
      duration: 1,
    );
    await cache.write(video.path, result, configurationScope: 'scope-a');
    await Future<void>.delayed(const Duration(milliseconds: 3));
    video.writeAsStringSync('changed');

    final VideoSubtitleCacheEntry entry = (await cache.inspect(
      configurationScope: 'scope-b',
    )).entries.single;
    expect(entry.isValid, isTrue);
    expect(entry.mediaMatches, isFalse);
    expect(entry.configurationMatches, isFalse);
  });

  test('超过容量时优先删除最旧且非保护的缓存', () async {
    const TranscriptionResult result = TranscriptionResult(
      segments: <Segment>[Segment(text: '字幕', start: 0, end: 1, index: 0)],
      duration: 1,
    );
    final File secondVideo = File(p.join(root.path, 'second.mp4'))
      ..writeAsStringSync('second');
    await cache.write(video.path, result);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await cache.write(secondVideo.path, result);
    final VideoSubtitleCacheSummary before = await cache.inspect();
    final int keepBytes = before.entries
        .firstWhere(
          (VideoSubtitleCacheEntry entry) =>
              entry.mediaPath == secondVideo.path,
        )
        .bytes;

    final VideoSubtitleCacheCleanupReport report = await cache.trimToMaxBytes(
      keepBytes,
      protectedMediaPaths: <String>{secondVideo.path},
    );

    expect(report.removedEntries, 1);
    expect(await cache.read(video.path), isNull);
    expect(await cache.read(secondVideo.path), isNotNull);
  });
}
