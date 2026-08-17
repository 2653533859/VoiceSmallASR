import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';

void main() {
  test('按 OpenAI-compatible 格式发送 endpoint、模型、认证和文本，并解析 JSON 数组', () async {
    final _FakeClient client = _FakeClient(
      _jsonResponse(<String, Object>{
        'choices': <Map<String, Object>>[
          <String, Object>{
            'message': <String, String>{'content': '["你好", "世界"]'},
          },
        ],
      }),
    );
    final ApiTranslationProvider provider = ApiTranslationProvider(
      apiKey: ' test-key ',
      endpoint: 'https://provider.example/v1/chat/completions',
      model: 'translate-model',
      client: client,
    );

    final List<String> result = await provider.translate(
      <String>['hello', 'world'],
      from: 'en',
      to: 'zh-CN',
    );

    expect(result, <String>['你好', '世界']);
    expect(
      client.uri,
      Uri.parse('https://provider.example/v1/chat/completions'),
    );
    expect(client.headers['Authorization'], 'Bearer test-key');
    final Map<String, dynamic> body =
        jsonDecode(client.body) as Map<String, dynamic>;
    expect(body['model'], 'translate-model');
    expect(body['temperature'], 0);
    final List<dynamic> messages = body['messages'] as List<dynamic>;
    final Map<String, dynamic> request =
        jsonDecode(messages[1]['content'] as String) as Map<String, dynamic>;
    expect(request, <String, dynamic>{
      'source_language': 'en',
      'target_language': 'zh-CN',
      'texts': <String>['hello', 'world'],
    });
  });

  test('兼容 translations 响应和单条普通文本响应', () async {
    final _FakeClient client = _FakeClient(
      _jsonResponse(<String, Object>{
        'translations': <String>['你好'],
      }),
    );
    final ApiTranslationProvider provider = ApiTranslationProvider(
      apiKey: 'key',
      client: client,
    );

    expect(await provider.translate(<String>['hello'], to: 'zh'), <String>[
      '你好',
    ]);

    client.response = _jsonResponse(<String, Object>{
      'choices': <Map<String, Object>>[
        <String, Object>{
          'message': <String, String>{'content': '你好'},
        },
      ],
    });
    expect(await provider.translate(<String>['hello'], to: 'zh'), <String>[
      '你好',
    ]);
  });

  test('术语表会注入系统提示，并校验每行格式和重复原词', () async {
    final _FakeClient client = _FakeClient(
      _jsonResponse(<String, Object>{
        'translations': <String>['你好'],
      }),
    );
    final ApiTranslationProvider provider = ApiTranslationProvider(
      apiKey: 'key',
      glossary: '# 注释\nASR = 自动语音识别\nVoiceSmall=语音小助手',
      client: client,
    );

    await provider.translate(<String>['ASR'], to: 'zh-CN');

    final Map<String, dynamic> body =
        jsonDecode(client.body) as Map<String, dynamic>;
    final List<dynamic> messages = body['messages'] as List<dynamic>;
    final String systemPrompt = messages[0]['content'] as String;
    expect(systemPrompt, contains('ASR'));
    expect(systemPrompt, contains('自动语音识别'));
    expect(systemPrompt, contains('VoiceSmall'));

    expect(() => parseTranslationGlossary('a=b\na=c'), throwsArgumentError);
    expect(parseTranslationGlossary(' # comment\n a = b '), <String, String>{
      'a': 'b',
    });
    expect(() => parseTranslationGlossary('invalid-line'), throwsArgumentError);
  });

  test('HTTP 错误不泄露 API Key，响应数量不一致时拒绝映射', () async {
    final _FakeClient client = _FakeClient(
      _jsonResponse(<String, Object>{
        'error': <String, String>{'message': 'quota exceeded'},
      }, statusCode: 429),
    );
    final ApiTranslationProvider provider = ApiTranslationProvider(
      apiKey: 'secret-key',
      client: client,
    );

    await expectLater(
      provider.translate(<String>['hello'], to: 'zh'),
      throwsA(
        isA<TranslationException>()
            .having(
              (TranslationException error) => error.statusCode,
              'statusCode',
              429,
            )
            .having(
              (TranslationException error) => error.toString(),
              'string',
              isNot(contains('secret-key')),
            ),
      ),
    );

    client.response = _jsonResponse(<String, Object>{
      'translations': <String>['一', '二'],
    });
    await expectLater(
      provider.translate(<String>['hello'], to: 'zh'),
      throwsA(isA<TranslationException>()),
    );
  });

  test('测试连接使用最小文本请求并复用正常响应校验', () async {
    final _FakeClient client = _FakeClient(
      _jsonResponse(<String, Object>{
        'translations': <String>['连接测试完成'],
      }),
    );
    final ApiTranslationProvider provider = ApiTranslationProvider(
      apiKey: 'key',
      client: client,
    );

    await provider.testConnection(targetLanguage: 'ja');

    final Map<String, dynamic> body =
        jsonDecode(client.body) as Map<String, dynamic>;
    final List<dynamic> messages = body['messages'] as List<dynamic>;
    final Map<String, dynamic> request =
        jsonDecode(messages[1]['content'] as String) as Map<String, dynamic>;
    expect(request['target_language'], 'ja');
    expect(request['texts'], <String>['连接测试']);
  });

  test('构造时校验 API Key、地址、模型和超时', () {
    expect(() => ApiTranslationProvider(apiKey: ' '), throwsArgumentError);
    expect(
      () => ApiTranslationProvider(
        apiKey: 'key',
        endpoint: 'ftp://provider.example/api',
      ),
      throwsArgumentError,
    );
    expect(
      () => ApiTranslationProvider(apiKey: 'key', model: ' '),
      throwsArgumentError,
    );
    expect(
      () => ApiTranslationProvider(apiKey: 'key', timeout: Duration.zero),
      throwsArgumentError,
    );
  });
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.response);

  http.Response response;
  Uri? uri;
  Map<String, String> headers = <String, String>{};
  String body = '';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
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

http.Response _jsonResponse(Object body, {int statusCode = 200}) =>
    http.Response(
      jsonEncode(body),
      statusCode,
      headers: <String, String>{'content-type': 'application/json'},
    );
