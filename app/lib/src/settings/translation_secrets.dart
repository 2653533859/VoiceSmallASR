/// 翻译服务的密钥安全存储。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 第三方翻译 API Key 在系统安全存储中的固定键名。
const String kTranslationApiKeyStorageKey = 'translation.api_key';

/// 旧版 DeepL 配置的键名，仅用于升级时清理。
const String kLegacyDeepLApiKeyStorageKey = 'translation.deepl.api_key';

/// 兼容旧调用方的常量，新的代码应使用 [kTranslationApiKeyStorageKey]。
@Deprecated('请使用 kTranslationApiKeyStorageKey')
const String kDeepLApiKeyStorageKey = kLegacyDeepLApiKeyStorageKey;

/// 可替换的密钥存储契约，便于在没有平台 channel 的单测里验证配置逻辑。
abstract interface class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// 基于 flutter_secure_storage 的跨平台实现。
class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 第三方翻译 API 配置使用的密钥服务。
///
/// 只返回去掉首尾空白的密钥，不记录、不缓存，也不把密钥复制到普通配置文件。
class TranslationSecrets {
  TranslationSecrets({SecretStore? store})
    : _store = store ?? FlutterSecureSecretStore();

  final SecretStore _store;
  String? _sessionApiKey;
  bool _sessionOnly = false;

  /// 无签名 macOS 包无法使用 Keychain Sharing 时，API Key 只保留在当前进程内。
  ///
  /// 这个回退不把密钥写入普通配置或明文文件；应用退出后需要重新输入。
  bool get sessionOnly => _sessionOnly;

  Future<String?> readApiKey() async {
    try {
      final String? value = await _store.read(kTranslationApiKeyStorageKey);
      final String key = (value ?? '').trim();
      _sessionOnly = false;
      return key.isEmpty ? _sessionApiKey : key;
    } on Object {
      _sessionOnly = true;
      return _sessionApiKey;
    }
  }

  Future<void> saveApiKey(String apiKey) async {
    final String key = apiKey.trim();
    if (key.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'API Key 不能为空');
    }
    try {
      await _store.write(kTranslationApiKeyStorageKey, key);
      await _store.delete(kLegacyDeepLApiKeyStorageKey);
      _sessionApiKey = null;
      _sessionOnly = false;
    } on Object {
      _sessionApiKey = key;
      _sessionOnly = true;
    }
  }

  Future<void> deleteApiKey() async {
    _sessionApiKey = null;
    try {
      await _store.delete(kTranslationApiKeyStorageKey);
      await _store.delete(kLegacyDeepLApiKeyStorageKey);
    } on Object {
      // 无签名 macOS 的 Keychain 可能不可用；当前会话密钥已经清除即可。
      _sessionOnly = true;
    }
  }

  @Deprecated('请使用 readApiKey')
  Future<String?> readDeepLApiKey() => readApiKey();

  @Deprecated('请使用 saveApiKey')
  Future<void> saveDeepLApiKey(String apiKey) => saveApiKey(apiKey);

  @Deprecated('请使用 deleteApiKey')
  Future<void> deleteDeepLApiKey() => deleteApiKey();
}
