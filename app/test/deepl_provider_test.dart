import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vsasr_app/src/translation/deepl_provider.dart';

void main() {
  test('按 DeepL v2 请求格式发送认证、语言和文本，并按顺序解析译文', () async {
    final _FakeClient client = _FakeClient(
      http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, Object>{
            'translations': <Map<String, String>>[
              <String, String>{'text': '你好'},
              <String, String>{'text': '世界'},
            ],
          }),
        ),
        200,
        headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
      ),
    );
    final DeepLTranslationProvider provider = DeepLTranslationProvider(
      apiKey: ' test-key ',
      baseUrl: 'https://api-free.deepl.com/',
      client: client,
    );

    final List<String> result = await provider.translate(
      <String>['hello', 'world'],
      from: 'en',
      to: ' zh ',
    );

    expect(result, <String>['你好', '世界']);
    expect(client.uri, Uri.parse('https://api-free.deepl.com/v2/translate'));
    expect(client.headers['Authorization'], 'DeepL-Auth-Key test-key');
    final Map<String, dynamic> body = jsonDecode(client.body) as Map<String, dynamic>;
    expect(body, <String, dynamic>{
      'text': <String>['hello', 'world'],
      'target_lang': 'ZH',
      'source_lang': 'EN',
    });
  });

  test('自动检测时省略 source_lang，空文本不发网络请求', () async {
    final _FakeClient client = _FakeClient(http.Response('{}', 200));
    final DeepLTranslationProvider provider = DeepLTranslationProvider(
      apiKey: 'key',
      client: client,
    );

    expect(await provider.translate(const <String>[], to: 'zh'), isEmpty);
    expect(client.calls, 0);

    client.response = http.Response.bytes(
      utf8.encode(
        jsonEncode(<String, Object>{
          'translations': <Map<String, String>>[<String, String>{'text': '你好'}],
        }),
      ),
      200,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );
    expect(await provider.translate(<String>['hello'], to: 'zh'), <String>['你好']);
    final Map<String, dynamic> body = jsonDecode(client.body) as Map<String, dynamic>;
    expect(body.containsKey('source_lang'), isFalse);
  });

  test('HTTP 错误转成不泄露 API Key 的 TranslationException', () async {
    final _FakeClient client = _FakeClient(
      http.Response(jsonEncode(<String, String>{'message': 'quota exceeded'}), 456),
    );
    final DeepLTranslationProvider provider = DeepLTranslationProvider(
      apiKey: 'secret-key',
      client: client,
    );

    await expectLater(
      provider.translate(<String>['hello'], to: 'zh'),
      throwsA(
        isA<TranslationException>()
            .having((TranslationException error) => error.statusCode, 'statusCode', 456)
            .having((TranslationException error) => error.message, 'message', contains('quota exceeded'))
            .having((TranslationException error) => error.toString(), 'string', isNot(contains('secret-key'))),
      ),
    );
  });

  test('成功响应数量不匹配或格式错误时拒绝静默生成错误字幕', () async {
    final _FakeClient client = _FakeClient(
      http.Response(
        jsonEncode(<String, Object>{
          'translations': <Map<String, String>>[<String, String>{'wrong': 'field'}],
        }),
        200,
      ),
    );
    final DeepLTranslationProvider provider = DeepLTranslationProvider(
      apiKey: 'key',
      client: client,
    );

    await expectLater(
      provider.translate(<String>['hello'], to: 'zh'),
      throwsA(isA<TranslationException>()),
    );
  });

  test('单次请求超过 128 KiB 时按 UTF-8 请求体拆分，并保持结果顺序', () async {
    final _FakeClient client = _FakeClient(
      http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, Object>{
            'translations': <Map<String, String>>[<String, String>{'text': '译文'}],
          }),
        ),
        200,
        headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
      ),
    );
    final DeepLTranslationProvider provider = DeepLTranslationProvider(
      apiKey: 'key',
      client: client,
    );
    final List<String> texts = <String>['a' * 70000, 'b' * 70000];

    final List<String> translated = await provider.translate(texts, to: 'zh');

    expect(translated, <String>['译文', '译文']);
    expect(client.calls, 2);
  });

  test('构造时拒绝空 API Key、非法地址和非正超时', () {
    expect(
      () => DeepLTranslationProvider(apiKey: '  '),
      throwsArgumentError,
    );
    expect(
      () => DeepLTranslationProvider(apiKey: 'key', baseUrl: 'ftp://example.com'),
      throwsArgumentError,
    );
    expect(
      () => DeepLTranslationProvider(apiKey: 'key', timeout: Duration.zero),
      throwsArgumentError,
    );
  });
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.response);

  http.Response response;
  int calls = 0;
  Uri? uri;
  Map<String, String> headers = <String, String>{};
  String body = '';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    uri = request.url;
    headers = request.headers;
    body = await request.finalize().bytesToString();
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }
}
