import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/settings/translation_secrets.dart';

void main() {
  test('第三方翻译 API Key 写入前去空白，读取时也不返回空白值', () async {
    final _FakeSecretStore store = _FakeSecretStore();
    final TranslationSecrets secrets = TranslationSecrets(store: store);

    await secrets.saveApiKey('  api-secret  ');
    expect(store.values[kTranslationApiKeyStorageKey], 'api-secret');
    expect(await secrets.readApiKey(), 'api-secret');

    store.values[kTranslationApiKeyStorageKey] = '   ';
    expect(await secrets.readApiKey(), isNull);
  });

  test('空 API Key 拒绝写入，已有密钥可删除', () async {
    final _FakeSecretStore store = _FakeSecretStore();
    final TranslationSecrets secrets = TranslationSecrets(store: store);

    await expectLater(secrets.saveApiKey('  '), throwsArgumentError);
    expect(store.values, isEmpty);

    await secrets.saveApiKey('key');
    await secrets.deleteApiKey();
    expect(store.values, isEmpty);
  });

  test('密钥存储使用固定的 provider-specific 键，不混入普通配置', () async {
    final _FakeSecretStore store = _FakeSecretStore();
    final TranslationSecrets secrets = TranslationSecrets(store: store);

    await secrets.saveApiKey('key');

    expect(store.writes, <String>[kTranslationApiKeyStorageKey]);
    expect(store.writes.single, isNot('apiKey'));
  });

  test('旧 DeepL Key 不会被误用为新的第三方 API Key', () async {
    final _FakeSecretStore store = _FakeSecretStore()
      ..values[kLegacyDeepLApiKeyStorageKey] = 'old-deepl-key';
    final TranslationSecrets secrets = TranslationSecrets(store: store);

    expect(await secrets.readApiKey(), isNull);
    await secrets.saveApiKey('new-provider-key');
    expect(store.values[kTranslationApiKeyStorageKey], 'new-provider-key');
    expect(store.values.containsKey(kLegacyDeepLApiKeyStorageKey), isFalse);
  });

  test('系统安全存储不可用时只在当前会话保留 API Key', () async {
    final TranslationSecrets secrets = TranslationSecrets(
      store: _FailingSecretStore(),
    );

    expect(await secrets.readApiKey(), isNull);
    expect(secrets.sessionOnly, isTrue);

    await secrets.saveApiKey('session-key');
    expect(await secrets.readApiKey(), 'session-key');
    expect(secrets.sessionOnly, isTrue);

    await secrets.deleteApiKey();
    expect(await secrets.readApiKey(), isNull);
  });
}

class _FakeSecretStore implements SecretStore {
  final Map<String, String> values = <String, String>{};
  final List<String> writes = <String>[];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _FailingSecretStore implements SecretStore {
  StateError _failure() => StateError('Keychain Sharing unavailable');

  @override
  Future<String?> read(String key) async => throw _failure();

  @override
  Future<void> write(String key, String value) async => throw _failure();

  @override
  Future<void> delete(String key) async => throw _failure();
}
