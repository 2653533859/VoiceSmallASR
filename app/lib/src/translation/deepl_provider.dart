/// 兼容旧配置的 DeepL 在线翻译 provider。
///
/// 当前应用默认使用 `ApiTranslationProvider`；本类保留给旧调用方和兼容测试。
///
/// API 细节见：
/// https://developers.deepl.com/api-reference/translate/request-translation
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:vsasr_app/src/translation/translation_provider.dart';

export 'translation_provider.dart' show TranslationException;

/// DeepL 免费套餐的 API 地址；付费套餐可传 `https://api.deepl.com`。
const String kDeepLFreeApiBaseUrl = 'https://api-free.deepl.com';

/// DeepL Translate API 的单次 JSON 请求体上限（128 KiB）。
const int kDeepLMaxRequestBytes = 128 * 1024;

/// DeepL 翻译服务的 HTTP 实现。
///
/// [apiKey] 只在实例内用于请求头，不负责持久化；API Key 的安全存储由
/// 设置层负责。传入 [client] 后，调用方负责它的生命周期，便于测试和复用连接池。
class DeepLTranslationProvider implements ClosableTranslationProvider {
  DeepLTranslationProvider({
    required String apiKey,
    String baseUrl = kDeepLFreeApiBaseUrl,
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
  }) : _apiKey = _requireApiKey(apiKey),
       _endpoint = _buildEndpoint(baseUrl),
       _timeout = _requireTimeout(timeout),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String _apiKey;
  final Uri _endpoint;
  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) async {
    if (texts.isEmpty) return const <String>[];
    final String target = to.trim().toUpperCase();
    if (target.isEmpty) {
      throw ArgumentError.value(to, 'to', '目标语言不能为空');
    }

    final String source = (from ?? '').trim();
    final String? sourceLanguage = source.isEmpty || source == 'auto'
        ? null
        : source.toUpperCase();
    final List<String> translations = <String>[];
    for (final List<String> batch in _splitRequestTexts(
      texts,
      target,
      sourceLanguage,
    )) {
      translations.addAll(
        await _translateRequest(batch, target, sourceLanguage),
      );
    }
    return translations;
  }

  Future<List<String>> _translateRequest(
    List<String> texts,
    String target,
    String? source,
  ) async {
    final Map<String, Object> payload = _payload(texts, target, source);

    final http.Response response = await _client
        .post(
          _endpoint,
          headers: <String, String>{
            'Authorization': 'DeepL-Auth-Key $_apiKey',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(_timeout);

    final Object? decoded = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TranslationException(
        _errorMessage(decoded) ?? 'DeepL 请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['translations'] is! List<dynamic>) {
      throw const TranslationException('DeepL 返回缺少 translations 数组');
    }

    final List<dynamic> rawTranslations =
        decoded['translations'] as List<dynamic>;
    final List<String> translations = <String>[];
    for (final dynamic item in rawTranslations) {
      if (item is! Map<String, dynamic> || item['text'] is! String) {
        throw const TranslationException('DeepL 返回的 translations 项格式无效');
      }
      translations.add((item['text'] as String).trim());
    }
    if (translations.length != texts.length) {
      throw StateError(
        'DeepL 返回 ${translations.length} 条结果，需要 ${texts.length} 条，无法安全对应字幕',
      );
    }
    return translations;
  }

  /// 仅关闭 provider 自己创建的 HTTP client；注入的 client 由调用方管理。
  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

Map<String, Object> _payload(
  List<String> texts,
  String target,
  String? source,
) {
  final Map<String, Object> payload = <String, Object>{
    'text': texts,
    'target_lang': target,
  };
  if (source != null) payload['source_lang'] = source;
  return payload;
}

Iterable<List<String>> _splitRequestTexts(
  List<String> texts,
  String target,
  String? source,
) sync* {
  List<String> current = <String>[];
  for (final String text in texts) {
    final List<String> candidate = <String>[...current, text];
    if (_payloadBytes(candidate, target, source) <= kDeepLMaxRequestBytes) {
      current = candidate;
      continue;
    }
    if (current.isEmpty ||
        _payloadBytes(<String>[text], target, source) > kDeepLMaxRequestBytes) {
      throw const TranslationException('单条文本超过 DeepL 128 KiB 请求上限');
    }
    yield current;
    current = <String>[text];
  }
  if (current.isNotEmpty) yield current;
}

int _payloadBytes(List<String> texts, String target, String? source) =>
    utf8.encode(jsonEncode(_payload(texts, target, source))).length;

String _requireApiKey(String value) {
  final String key = value.trim();
  if (key.isEmpty) {
    throw ArgumentError.value(value, 'apiKey', 'API Key 不能为空');
  }
  return key;
}

Duration _requireTimeout(Duration value) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, 'timeout', '必须大于 0');
  }
  return value;
}

Uri _buildEndpoint(String baseUrl) {
  final Uri base;
  try {
    base = Uri.parse(baseUrl.trim());
  } on FormatException {
    throw ArgumentError.value(baseUrl, 'baseUrl', '不是有效的 URL');
  }
  if (base.host.isEmpty || (base.scheme != 'http' && base.scheme != 'https')) {
    throw ArgumentError.value(baseUrl, 'baseUrl', '必须是 http 或 https URL');
  }
  final String path = base.path.endsWith('/')
      ? '${base.path}v2/translate'
      : '${base.path}/v2/translate';
  return base.replace(path: path, query: null, fragment: null);
}

Object? _decodeJson(String body) {
  if (body.trim().isEmpty) return null;
  try {
    return jsonDecode(body);
  } on FormatException {
    return null;
  }
}

String? _errorMessage(Object? decoded) {
  if (decoded is Map<String, dynamic> && decoded['message'] is String) {
    final String message = (decoded['message'] as String).trim();
    if (message.isNotEmpty) return 'DeepL：$message';
  }
  return null;
}
