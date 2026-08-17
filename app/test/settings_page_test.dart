import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/settings/translation_secrets.dart';
import 'package:vsasr_app/src/settings/settings_page.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

void main() {
  testWidgets('设置页保存普通配置和第三方翻译 API Key，并立即应用到控制器', (WidgetTester tester) async {
    final _FakePreferenceStore preferences = _FakePreferenceStore();
    final _FakeSecretStore secrets = _FakeSecretStore();
    final AppSettingsRepository repository = AppSettingsRepository(
      preferences: preferences,
      secrets: TranslationSecrets(store: secrets),
    );
    final TranscribeController controller = TranscribeController();
    addTearDown(controller.shutdown);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(controller: controller, repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settingsLanguage')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日文').last);
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(400, 500), const Offset(0, -300));
    await tester.pump();
    final Finder glossaryField = find.byWidgetPredicate(
      (Widget widget) => widget is TextField &&
          widget.key == const Key('translationGlossary'),
    );
    await tester.enterText(glossaryField, 'ASR=自动语音识别');
    await tester.dragFrom(const Offset(400, 500), const Offset(0, -300));
    await tester.pump();
    final Finder apiKeyField = find.byWidgetPredicate(
      (Widget widget) =>
          widget is TextField && widget.key == const Key('translationApiKey'),
    );
    await tester.enterText(apiKeyField, '  saved-key  ');
    for (int i = 0; i < 3; i++) {
      await tester.dragFrom(const Offset(400, 300), const Offset(0, -400));
      await tester.pump();
    }
    await tester.tap(find.text('离线模式'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    expect(controller.config.language, 'ja');
    expect(await repository.loadConfig(), isA<AsrConfig>());
    expect((await repository.loadConfig()).language, 'ja');
    expect(secrets.values[kTranslationApiKeyStorageKey], 'saved-key');
    expect(
      (await repository.loadTranslationApiSettings()).glossary,
      'ASR=自动语音识别',
    );
    expect(controller.offlineMode, isTrue);
    expect(await repository.loadOfflineMode(), isTrue);
  });

  testWidgets('设置页打开时恢复已保存的 API Key，但不显示明文', (WidgetTester tester) async {
    final _FakeSecretStore secrets = _FakeSecretStore()
      ..values[kTranslationApiKeyStorageKey] = 'saved-key';
    final AppSettingsRepository repository = AppSettingsRepository(
      preferences: _FakePreferenceStore(),
      secrets: TranslationSecrets(store: secrets),
    );
    final TranscribeController controller = TranscribeController();
    addTearDown(controller.shutdown);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(controller: controller, repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('translationTargetLanguage')), findsOneWidget);
    for (int i = 0; i < 2; i++) {
      await tester.dragFrom(const Offset(400, 500), const Offset(0, -300));
      await tester.pump();
    }
    final Finder apiKeyField = find.byWidgetPredicate(
      (Widget widget) =>
          widget is TextField && widget.key == const Key('translationApiKey'),
    );
    final TextField field = tester.widget<TextField>(apiKeyField);
    expect(field.obscureText, isTrue);
    expect(field.controller?.text, 'saved-key');
    expect(
      find.byWidgetPredicate(
        (Widget widget) => widget is Text && widget.data == 'saved-key',
      ),
      findsNothing,
    );
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
