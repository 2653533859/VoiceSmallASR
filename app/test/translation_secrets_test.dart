import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/settings/translation_secrets.dart';

void main() {
  test('DeepL API Key 写入前去空白，读取时也不返回空白值', () async {
    final _FakeSecretStore store = _FakeSecretStore();
    final TranslationSecrets secrets = TranslationSecrets(store: store);

    await secrets.saveDeepLApiKey('  deep-secret  ');
    expect(store.values[kDeepLApiKeyStorageKey], 'deep-secret');
    expect(await secrets.readDeepLApiKey(), 'deep-secret');

    store.values[kDeepLApiKeyStorageKey] = '   ';
    expect(await secrets.readDeepLApiKey(), isNull);
  });

  test('空 API Key 拒绝写入，已有密钥可删除', () async {
    final _FakeSecretStore store = _FakeSecretStore();
    final TranslationSecrets secrets = TranslationSecrets(store: store);

    await expectLater(
      secrets.saveDeepLApiKey('  '),
      throwsArgumentError,
    );
    expect(store.values, isEmpty);

    await secrets.saveDeepLApiKey('key');
    await secrets.deleteDeepLApiKey();
    expect(store.values, isEmpty);
  });

  test('密钥存储使用固定的 provider-specific 键，不混入普通配置', () async {
    final _FakeSecretStore store = _FakeSecretStore();
    final TranslationSecrets secrets = TranslationSecrets(store: store);

    await secrets.saveDeepLApiKey('key');

    expect(store.writes, <String>[kDeepLApiKeyStorageKey]);
    expect(store.writes.single, isNot('apiKey'));
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
