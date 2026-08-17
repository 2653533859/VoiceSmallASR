/// OpenAI-compatible Chat Completions 翻译 provider。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:vsasr_app/src/translation/translation_provider.dart';

/// 常见 OpenAI-compatible 服务的默认地址；第三方服务可在设置中覆盖。
const String kDefaultTranslationApiEndpoint =
    'https://api.openai.com/v1/chat/completions';

const String kDefaultTranslationApiModel = 'gpt-4o-mini';
const String kDefaultTranslationTargetLanguage = 'zh-CN';

/// 设置页提供的目标语言。provider 本身仍接受任意非空语言标识，方便第三方扩展。
const Map<String, String> kTranslationLanguageLabels = <String, String>{
  'zh-CN': '中文（简体）',
  'en': '英文',
  'ja': '日文',
  'ko': '韩文',
  'yue': '粤语',
};

const List<String> kTranslationLanguages = <String>[
  'zh-CN',
  'en',
  'ja',
  'ko',
  'yue',
];

/// 用户可配置的第三方翻译 API 参数。
class TranslationApiSettings {
  const TranslationApiSettings({
    this.endpoint = kDefaultTranslationApiEndpoint,
    this.model = kDefaultTranslationApiModel,
    this.targetLanguage = kDefaultTranslationTargetLanguage,
    this.glossary = '',
  });

  final String endpoint;
  final String model;
  final String targetLanguage;

  /// 每行一个 `原词=译词`，空行和 `#` 开头的行会被忽略。
  final String glossary;
}

/// 使用 OpenAI-compatible Chat Completions 协议的翻译服务。
///
/// 请求使用 `messages`，要求模型只返回与输入等长的 JSON 字符串数组，
/// 因此兼容大多数提供 OpenAI API 格式的第三方服务。API Key 只存在于
/// provider 实例中，持久化由设置层的安全存储负责。
class ApiTranslationProvider implements ClosableTranslationProvider {
  ApiTranslationProvider({
    required String apiKey,
    String endpoint = kDefaultTranslationApiEndpoint,
    String model = kDefaultTranslationApiModel,
    String glossary = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
  }) : _apiKey = _requireApiKey(apiKey),
       _endpoint = _buildEndpoint(endpoint),
       _model = _requireModel(model),
       _glossary = parseTranslationGlossary(glossary),
       _timeout = _requireTimeout(timeout),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String _apiKey;
  final Uri _endpoint;
  final String _model;
  final Map<String, String> _glossary;
  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;

  /// 发送一条最小请求，验证 endpoint、模型和 API Key 是否可用。
  ///
  /// 不返回或记录测试文本，调用方只需根据是否抛错展示连接结果。
  Future<void> testConnection({
    String targetLanguage = kDefaultTranslationTargetLanguage,
  }) async {
    await translate(<String>['连接测试'], to: targetLanguage);
  }

  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) async {
    if (texts.isEmpty) return const <String>[];
    final String target = to.trim();
    if (target.isEmpty) {
      throw ArgumentError.value(to, 'to', '目标语言不能为空');
    }
    if (texts.any((String text) => text.trim().isEmpty)) {
      throw ArgumentError.value(texts, 'texts', '不能包含空文本');
    }

    final Map<String, Object> payload = _payload(texts, from, target);
    final http.Response response = await _client
        .post(
          _endpoint,
          headers: <String, String>{
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(_timeout);

    final Object? decoded = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TranslationException(
        _errorMessage(decoded) ?? '翻译 API 请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    return _parseTranslations(decoded, expected: texts.length);
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }

  Map<String, Object> _payload(
    List<String> texts,
    String? from,
    String target,
  ) {
    final String source = (from ?? '').trim();
    final String glossaryInstruction = _glossary.isEmpty
        ? ''
        : '必须优先使用以下术语表中的译法：${jsonEncode(_glossary)}。术语表中未出现的词按上下文翻译。';
    return <String, Object>{
      'model': _model,
      'temperature': 0,
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content':
              '你是字幕翻译引擎。将输入的每条文本翻译成目标语言，保持原意、语气和顺序。'
              '只返回 JSON 字符串数组，数组长度必须与输入文本数量相同，不要添加解释、Markdown 或代码围栏。'
              '$glossaryInstruction',
        },
        <String, String>{
          'role': 'user',
          'content': jsonEncode(<String, Object>{
            'source_language': source.isEmpty || source == 'auto'
                ? 'auto'
                : source,
            'target_language': target,
            'texts': texts,
          }),
        },
      ],
    };
  }
}

/// 解析并校验设置页填写的术语表。
Map<String, String> parseTranslationGlossary(String raw) {
  final Map<String, String> terms = <String, String>{};
  for (final String rawLine in raw.replaceAll('\r\n', '\n').split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final int separator = line.indexOf('=');
    if (separator <= 0 || separator == line.length - 1) {
      throw ArgumentError.value(raw, 'glossary', '术语表每行必须是“原词=译词”，空行和 # 注释行除外');
    }
    final String source = line.substring(0, separator).trim();
    final String target = line.substring(separator + 1).trim();
    if (source.isEmpty || target.isEmpty) {
      throw ArgumentError.value(raw, 'glossary', '术语表的原词和译词不能为空');
    }
    if (terms.containsKey(source)) {
      throw ArgumentError.value(raw, 'glossary', '术语表不能包含重复原词：$source');
    }
    terms[source] = target;
  }
  return Map<String, String>.unmodifiable(terms);
}

Object? _decodeJson(String body) {
  if (body.trim().isEmpty) return null;
  try {
    return jsonDecode(body);
  } on FormatException {
    return null;
  }
}

List<String> _parseTranslations(Object? decoded, {required int expected}) {
  if (decoded is! Map<String, dynamic>) {
    throw const TranslationException('翻译 API 返回的 JSON 格式无效');
  }
  final dynamic direct = decoded['translations'];
  if (direct is List<dynamic>) {
    return _readStringList(direct, expected: expected);
  }

  final dynamic choices = decoded['choices'];
  if (choices is! List<dynamic> ||
      choices.isEmpty ||
      choices.first is! Map<String, dynamic>) {
    throw const TranslationException('翻译 API 返回缺少 choices 或 translations');
  }
  final dynamic message = (choices.first as Map<String, dynamic>)['message'];
  if (message is! Map<String, dynamic>) {
    throw const TranslationException('翻译 API 返回缺少 choices[0].message');
  }
  final String content = _contentText(message['content']);
  final Object? parsed = _decodeJson(_stripCodeFence(content));
  if (parsed is List<dynamic>) {
    return _readStringList(parsed, expected: expected);
  }
  if (parsed is Map<String, dynamic> &&
      parsed['translations'] is List<dynamic>) {
    return _readStringList(
      parsed['translations'] as List<dynamic>,
      expected: expected,
    );
  }
  if (expected == 1 && content.trim().isNotEmpty) {
    return <String>[content.trim()];
  }
  throw const TranslationException('翻译 API 返回的 content 不是 JSON 字符串数组');
}

List<String> _readStringList(List<dynamic> values, {required int expected}) {
  if (values.length != expected ||
      values.any((dynamic value) => value is! String)) {
    throw TranslationException(
      '翻译 API 返回 ${values.length} 条结果，需要 $expected 条，无法安全对应字幕',
    );
  }
  return values.map((dynamic value) => (value as String).trim()).toList();
}

String _contentText(dynamic content) {
  if (content is String) return content;
  if (content is List<dynamic>) {
    final StringBuffer buffer = StringBuffer();
    for (final dynamic item in content) {
      if (item is Map<String, dynamic> && item['text'] is String) {
        buffer.write(item['text']);
      }
    }
    return buffer.toString();
  }
  throw const TranslationException('翻译 API 返回的 message.content 格式无效');
}

String _stripCodeFence(String value) {
  final String trimmed = value.trim();
  final RegExpMatch? fenced = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$')
      .firstMatch(trimmed);
  return fenced?.group(1)?.trim() ?? trimmed;
}

String? _errorMessage(Object? decoded) {
  if (decoded is Map<String, dynamic>) {
    final dynamic error = decoded['error'];
    if (error is Map<String, dynamic> && error['message'] is String) {
      final String message = (error['message'] as String).trim();
      if (message.isNotEmpty) return '翻译 API：$message';
    }
    if (decoded['message'] is String) {
      final String message = (decoded['message'] as String).trim();
      if (message.isNotEmpty) return '翻译 API：$message';
    }
  }
  return null;
}

String _requireApiKey(String value) {
  final String key = value.trim();
  if (key.isEmpty) throw ArgumentError.value(value, 'apiKey', 'API Key 不能为空');
  return key;
}

String _requireModel(String value) {
  final String model = value.trim();
  if (model.isEmpty) throw ArgumentError.value(value, 'model', '模型名不能为空');
  return model;
}

Duration _requireTimeout(Duration value) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, 'timeout', '必须大于 0');
  }
  return value;
}

Uri _buildEndpoint(String value) {
  final Uri endpoint;
  try {
    endpoint = Uri.parse(value.trim());
  } on FormatException {
    throw ArgumentError.value(value, 'endpoint', '不是有效的 URL');
  }
  if (endpoint.host.isEmpty ||
      (endpoint.scheme != 'http' && endpoint.scheme != 'https')) {
    throw ArgumentError.value(value, 'endpoint', '必须是 http 或 https URL');
  }
  return endpoint;
}
