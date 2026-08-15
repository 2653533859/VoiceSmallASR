import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';

void main() {
  test('translateResult 只发送非空段，并按原位置写回译文', () async {
    final _FakeProvider provider = _FakeProvider();
    const TranscriptionResult source = TranscriptionResult(
      language: 'en',
      duration: 4.0,
      segments: <Segment>[
        Segment(text: ' hello ', start: 0.0, end: 1.0, index: 0),
        Segment(text: '  ', start: 1.0, end: 2.0, index: 1),
        Segment(text: 'world', start: 2.0, end: 4.0, index: 2),
      ],
    );

    final TranscriptionResult translated = await translateResult(
      source,
      provider,
      to: ' zh ',
    );

    expect(provider.texts, <String>['hello', 'world']);
    expect(provider.from, 'en');
    expect(provider.to, 'zh');
    expect(translated.segments[0].translation, '译文：hello');
    expect(translated.segments[1].translation, isNull);
    expect(translated.segments[2].translation, '译文：world');
    expect(translated.segments[2].start, 2.0);
    expect(translated.duration, 4.0);
  });

  test('自动语言不强行传 source，空结果不调用服务商', () async {
    final _FakeProvider provider = _FakeProvider();
    const TranscriptionResult empty = TranscriptionResult();

    final TranscriptionResult result = await translateResult(empty, provider, to: 'zh');

    expect(result, same(empty));
    expect(provider.calls, 0);
    expect(provider.from, isNull);
  });

  test('服务商返回数量不一致时拒绝生成部分译文', () async {
    final _FakeProvider provider = _FakeProvider(resultCount: 1);
    const TranscriptionResult source = TranscriptionResult(
      segments: <Segment>[
        Segment(text: '第一句', start: 0.0, end: 1.0, index: 0),
        Segment(text: '第二句', start: 1.0, end: 2.0, index: 1),
      ],
    );

    await expectLater(
      translateResult(source, provider, to: 'zh', maxRetries: 0),
      throwsA(isA<StateError>()),
    );
  });

  test('按批次翻译并报告累计进度', () async {
    final _FakeProvider provider = _FakeProvider();
    final List<List<int>> progress = <List<int>>[];
    const TranscriptionResult source = TranscriptionResult(
      language: 'en',
      segments: <Segment>[
        Segment(text: 'one', start: 0.0, end: 1.0),
        Segment(text: 'two', start: 1.0, end: 2.0),
        Segment(text: 'three', start: 2.0, end: 3.0),
      ],
    );

    final TranscriptionResult translated = await translateResult(
      source,
      provider,
      to: 'zh',
      batchSize: 2,
      maxRetries: 0,
      onProgress: (int done, int total) => progress.add(<int>[done, total]),
    );

    expect(provider.batches, <List<String>>[
      <String>['one', 'two'],
      <String>['three'],
    ]);
    expect(progress, <List<int>>[
      <int>[0, 3],
      <int>[2, 3],
      <int>[3, 3],
    ]);
    expect(translated.segments.map((Segment s) => s.translation), <String?>[
      '译文：one',
      '译文：two',
      '译文：three',
    ]);
  });

  test('临时服务商失败时按 maxRetries 重试，成功后才报告进度', () async {
    final _FakeProvider provider = _FakeProvider(failuresBeforeSuccess: 2);
    final List<List<int>> progress = <List<int>>[];
    const TranscriptionResult source = TranscriptionResult(
      segments: <Segment>[Segment(text: 'hello', start: 0.0, end: 1.0)],
    );

    await translateResult(
      source,
      provider,
      to: 'zh',
      maxRetries: 2,
      retryDelay: Duration.zero,
      onProgress: (int done, int total) => progress.add(<int>[done, total]),
    );

    expect(provider.calls, 3);
    expect(progress, <List<int>>[
      <int>[0, 1],
      <int>[1, 1],
    ]);
  });

  test('目标语言为空时在调用服务商前报错', () async {
    final _FakeProvider provider = _FakeProvider();

    await expectLater(
      translateResult(
        const TranscriptionResult(
          segments: <Segment>[Segment(text: 'hello', start: 0.0, end: 1.0)],
        ),
        provider,
        to: '  ',
      ),
      throwsArgumentError,
    );
    expect(provider.calls, 0);
  });
}

class _FakeProvider implements TranslationProvider {
  _FakeProvider({this.resultCount, this.failuresBeforeSuccess = 0});

  final int? resultCount;
  int failuresBeforeSuccess;
  int calls = 0;
  List<String> texts = <String>[];
  List<List<String>> batches = <List<String>>[];
  String? from;
  String? to;

  @override
  Future<List<String>> translate(
    List<String> values, {
    String? from,
    required String to,
  }) async {
    calls++;
    texts = List<String>.of(values);
    batches.add(List<String>.of(values));
    this.from = from;
    this.to = to;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw StateError('临时翻译失败');
    }
    final int count = resultCount ?? values.length;
    return values.take(count).map((String value) => '译文：$value').toList();
  }
}
