import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/settings/translation_secrets.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';

void main() {
  test('普通识别设置可以保存并在下一次加载时恢复', () async {
    final _FakePreferenceStore preferences = _FakePreferenceStore();
    final AppSettingsRepository repository = AppSettingsRepository(
      preferences: preferences,
    );
    final AsrConfig saved = AsrConfig(
      language: 'ja',
      useItn: false,
      numThreads: 8,
      partialInterval: 1.2,
      vad: const VadConfig(
        threshold: 0.7,
        minSilenceDuration: 0.8,
        minSpeechDuration: 0.3,
        maxSpeechDuration: 30.0,
      ),
    );

    await repository.saveConfig(saved);
    final AsrConfig loaded = await repository.loadConfig();

    expect(loaded.language, 'ja');
    expect(loaded.useItn, isFalse);
    expect(loaded.numThreads, 8);
    expect(loaded.partialInterval, 1.2);
    expect(loaded.vad.threshold, 0.7);
    expect(loaded.vad.minSilenceDuration, 0.8);
    expect(loaded.vad.minSpeechDuration, 0.3);
    expect(loaded.vad.maxSpeechDuration, 30.0);
  });

  test('损坏或越界的普通设置回退到默认值', () async {
    final _FakePreferenceStore preferences = _FakePreferenceStore()
      ..strings['settings.asr.language'] = 'fr'
      ..ints['settings.asr.num_threads'] = 0
      ..doubles['settings.asr.partial_interval'] = double.nan
      ..doubles['settings.vad.threshold'] = 2.0
      ..doubles['settings.vad.min_silence_duration'] = -1.0;
    final AppSettingsRepository repository = AppSettingsRepository(
      preferences: preferences,
    );

    final AsrConfig loaded = await repository.loadConfig();
    final AsrConfig defaults = AsrConfig();

    expect(loaded.language, defaults.language);
    expect(loaded.numThreads, defaults.numThreads);
    expect(loaded.partialInterval, defaults.partialInterval);
    expect(loaded.vad.threshold, defaults.vad.threshold);
    expect(loaded.vad.minSilenceDuration, defaults.vad.minSilenceDuration);
  });

  test('普通设置和 API Key 使用不同的存储通道', () async {
    final _FakePreferenceStore preferences = _FakePreferenceStore();
    final _FakeSecretStore secrets = _FakeSecretStore();
    final AppSettingsRepository repository = AppSettingsRepository(
      preferences: preferences,
      secrets: TranslationSecrets(store: secrets),
    );

    await repository.saveConfig(AsrConfig(language: 'en'));
    await repository.translationSecrets.saveApiKey('key');

    expect(preferences.strings.values, isNot(contains('key')));
    expect(secrets.values[kTranslationApiKeyStorageKey], 'key');
  });

  test('离线模式可以持久化', () async {
    final _FakePreferenceStore preferences = _FakePreferenceStore();
    final AppSettingsRepository repository = AppSettingsRepository(
      preferences: preferences,
    );

    expect(await repository.loadOfflineMode(), isFalse);
    await repository.saveOfflineMode(true);
    expect(await repository.loadOfflineMode(), isTrue);
  });

  test('最近项目会去重、置顶并限制数量，损坏数据回退为空列表', () async {
    final _FakePreferenceStore preferences = _FakePreferenceStore();
    final AppSettingsRepository repository = AppSettingsRepository(
      preferences: preferences,
    );

    for (int index = 0; index < kMaxRecentProjects + 2; index++) {
      await repository.rememberRecentProject('/tmp/project-$index.json');
    }
    List<String> recent = await repository.loadRecentProjects();
    expect(recent, hasLength(kMaxRecentProjects));
    expect(recent.first, '/tmp/project-${kMaxRecentProjects + 1}.json');
    expect(recent, isNot(contains('/tmp/project-0.json')));

    recent = await repository.rememberRecentProject('/tmp/project-3.json');
    expect(recent.first, '/tmp/project-3.json');
    expect(
      recent.where((String path) => path == '/tmp/project-3.json'),
      hasLength(1),
    );

    preferences.strings['settings.projects.recent'] = '{bad json';
    expect(await repository.loadRecentProjects(), isEmpty);
  });

  test('最近项目可以移除指定路径', () async {
    final _FakePreferenceStore preferences = _FakePreferenceStore();
    final AppSettingsRepository repository = AppSettingsRepository(
      preferences: preferences,
    );
    await repository.rememberRecentProject('/tmp/a.json');
    await repository.rememberRecentProject('/tmp/b.json');

    final List<String> recent = await repository.forgetRecentProject(
      '/tmp/a.json',
    );
    expect(recent, <String>['/tmp/b.json']);
  });

  test('第三方翻译 API 地址和模型可以持久化，但不包含 API Key', () async {
    final _FakePreferenceStore preferences = _FakePreferenceStore();
    final AppSettingsRepository repository = AppSettingsRepository(
      preferences: preferences,
    );
    const TranslationApiSettings saved = TranslationApiSettings(
      endpoint: 'https://provider.example/v1/chat/completions',
      model: 'provider-translate',
      targetLanguage: 'ja',
    );

    await repository.saveTranslationApiSettings(saved);
    final TranslationApiSettings loaded = await repository
        .loadTranslationApiSettings();

    expect(loaded.endpoint, saved.endpoint);
    expect(loaded.model, saved.model);
    expect(loaded.targetLanguage, saved.targetLanguage);
    expect(preferences.strings.values, isNot(contains('secret')));
  });
}

class _FakePreferenceStore implements PreferenceStore {
  final Map<String, String> strings = <String, String>{};
  final Map<String, bool> bools = <String, bool>{};
  final Map<String, int> ints = <String, int>{};
  final Map<String, double> doubles = <String, double>{};

  @override
  Future<String?> readString(String key) async => strings[key];

  @override
  Future<bool?> readBool(String key) async => bools[key];

  @override
  Future<int?> readInt(String key) async => ints[key];

  @override
  Future<double?> readDouble(String key) async => doubles[key];

  @override
  Future<void> writeString(String key, String value) async {
    strings[key] = value;
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    bools[key] = value;
  }

  @override
  Future<void> writeInt(String key, int value) async {
    ints[key] = value;
  }

  @override
  Future<void> writeDouble(String key, double value) async {
    doubles[key] = value;
  }
}

class _FakeSecretStore implements SecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
