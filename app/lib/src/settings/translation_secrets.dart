/// 翻译服务的密钥安全存储。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// DeepL API Key 在系统安全存储中的固定键名。
const String kDeepLApiKeyStorageKey = 'translation.deepl.api_key';

/// 可替换的密钥存储契约，便于在没有平台 channel 的单测里验证配置逻辑。
abstract interface class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// 基于 flutter_secure_storage 的跨平台实现。
class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore({FlutterSecureStorage? storage}) : _storage = storage ?? FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// DeepL 配置使用的密钥服务。
///
/// 只返回去掉首尾空白的密钥，不记录、不缓存，也不把密钥复制到普通配置文件。
class TranslationSecrets {
  TranslationSecrets({SecretStore? store}) : _store = store ?? FlutterSecureSecretStore();

  final SecretStore _store;

  Future<String?> readDeepLApiKey() async {
    final String? value = await _store.read(kDeepLApiKeyStorageKey);
    final String key = (value ?? '').trim();
    return key.isEmpty ? null : key;
  }

  Future<void> saveDeepLApiKey(String apiKey) async {
    final String key = apiKey.trim();
    if (key.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'API Key 不能为空');
    }
    await _store.write(kDeepLApiKeyStorageKey, key);
  }

  Future<void> deleteDeepLApiKey() => _store.delete(kDeepLApiKeyStorageKey);
}
