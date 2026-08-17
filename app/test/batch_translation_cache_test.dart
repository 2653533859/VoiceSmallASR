import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/project/batch_translation_cache.dart';

void main() {
  late Directory root;
  late BatchTranslationCache cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('vsasr_translation_cache_test');
    cache = BatchTranslationCache(rootDirectory: root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  const TranscriptionResult source = TranscriptionResult(
    language: 'en',
    duration: 1,
    segments: <Segment>[
      Segment(text: 'hello', start: 0, end: 1, language: 'en', index: 0),
    ],
  );
  final TranscriptionResult translated = source.copyWith(
    segments: <Segment>[source.segments.single.copyWith(translation: '你好')],
  );

  test('写入后可以按源结果、目标语言和 provider 配置复用', () async {
    await cache.write(
      mediaPath: '/tmp/hello.wav',
      translated: translated,
      targetLanguage: 'zh',
      providerScope: 'https://example.test\nmodel-a',
    );

    final TranscriptionResult? result = await cache.read(
      mediaPath: '/tmp/hello.wav',
      source: source,
      targetLanguage: 'zh',
      providerScope: 'https://example.test\nmodel-a',
    );

    expect(result?.segments.single.translation, '你好');
  });

  test('路径、目标语言、provider 或源结果变化都会缓存未命中', () async {
    await cache.write(
      mediaPath: '/tmp/hello.wav',
      translated: translated,
      targetLanguage: 'zh',
      providerScope: 'provider-a',
    );

    Future<TranscriptionResult?> read({
      String path = '/tmp/hello.wav',
      String target = 'zh',
      String provider = 'provider-a',
      TranscriptionResult input = source,
    }) {
      return cache.read(
        mediaPath: path,
        source: input,
        targetLanguage: target,
        providerScope: provider,
      );
    }

    expect(await read(path: '/tmp/other.wav'), isNull);
    expect(await read(target: 'ja'), isNull);
    expect(await read(provider: 'provider-b'), isNull);
    expect(
      await read(
        input: source.copyWith(
          segments: <Segment>[
            source.segments.single.copyWith(text: 'hello again'),
          ],
        ),
      ),
      isNull,
    );
  });

  test('缓存文件损坏时按未命中处理', () async {
    await cache.write(
      mediaPath: '/tmp/hello.wav',
      translated: translated,
      targetLanguage: 'zh',
      providerScope: 'provider-a',
    );
    final File file = File(
      p.join(root.path, 'batch_translation_cache', 'translations.json'),
    );
    await file.writeAsString('{not-json');

    expect(
      await cache.read(
        mediaPath: '/tmp/hello.wav',
        source: source,
        targetLanguage: 'zh',
        providerScope: 'provider-a',
      ),
      isNull,
    );
  });

  test('没有译文的结果不会被当作可复用缓存', () async {
    await cache.write(
      mediaPath: '/tmp/empty-translation.wav',
      translated: source,
      targetLanguage: 'zh',
      providerScope: 'provider-a',
    );

    expect(
      await cache.read(
        mediaPath: '/tmp/empty-translation.wav',
        source: source,
        targetLanguage: 'zh',
        providerScope: 'provider-a',
      ),
      isNull,
    );
  });

  test('缓存只保存翻译结果，不保存认证信息，并限制条目数量', () async {
    for (int index = 0; index < kMaxBatchTranslationCacheEntries + 1; index++) {
      await cache.write(
        mediaPath: '/tmp/$index.wav',
        translated: translated,
        targetLanguage: 'zh',
        providerScope: 'provider-a|secret-api-key',
      );
    }
    final File file = File(
      p.join(root.path, 'batch_translation_cache', 'translations.json'),
    );
    final Map<String, dynamic> document =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final Map<String, dynamic> entries =
        document['entries'] as Map<String, dynamic>;

    expect(entries, hasLength(kMaxBatchTranslationCacheEntries));
    expect(await file.readAsString(), isNot(contains('secret-api-key')));
  });
}
