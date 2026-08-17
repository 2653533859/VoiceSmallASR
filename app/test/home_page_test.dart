/// 主界面的 widget 测试：模型下载页 → 选文件 → 分段列表 → 导出。
///
/// 全部依赖都用替身，不起 isolate、不加载原生库、不弹真实文件对话框。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/settings/translation_secrets.dart';
import 'package:vsasr_app/src/ui/home_page.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';

import 'support/fake_asr.dart';

void main() {
  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('vsasr_ui_test'));
  tearDown(() => workspace.deleteSync(recursive: true));

  /// 造一个控制器：默认模型已就绪、转写器是进程内替身。
  TranscribeController build({
    bool modelReady = true,
    AudioDecoder? decoder,
    AudioDecodeException? decodeFailure,
    String text = '呢几个字都表达唔到',
  }) {
    if (modelReady) writeFakeModel(workspace.path);
    return TranscribeController(
      decoder: decoder ?? FakeDecoder(failure: decodeFailure),
      models: ModelManager(root: workspace.path),
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            onModelProgress('下载 model.tar.bz2（源 1/3）', 40, 100);
            return FakeTranscriber(language: config.language, text: text);
          },
    );
  }

  Future<void> show(
    WidgetTester tester,
    TranscribeController controller, {
    PickFile? pickFile,
    SaveFile? saveFile,
    AppSettingsRepository? settings,
    TranslationProviderFactory? translationProviderFactory,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          controller: controller,
          pickFile: pickFile,
          saveFile: saveFile,
          settings: settings,
          translationProviderFactory: translationProviderFactory,
        ),
      ),
    );
    // postFrameCallback 里的 refreshModel 是异步的，再走一帧才能看到结果
    await tester.pump();
    await tester.pump();
  }

  testWidgets('模型缺失时先显示下载页，下载完成后进入主界面', (WidgetTester tester) async {
    final TranscribeController controller = build(modelReady: false);
    addTearDown(controller.shutdown);
    await show(tester, controller);

    expect(find.text('首次使用需要下载模型'), findsOneWidget);
    expect(find.textContaining('依次尝试 GitHub 与两个镜像源'), findsOneWidget);
    expect(find.text('选择音频/视频'), findsNothing);

    await tester.tap(find.text('下载模型'));
    await tester.pump(); // 进入 preparingModel
    await tester.pump(); // 替身返回，模型就绪

    expect(find.text('选择音频/视频'), findsOneWidget);
    expect(find.text('选一个音频或视频文件开始'), findsOneWidget);
  });

  testWidgets('模型准备失败时显示错误并把按钮改成重试', (WidgetTester tester) async {
    final TranscribeController controller = TranscribeController(
      models: ModelManager(root: workspace.path),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => throw StateError('三个源都没下成：连接超时'),
    );
    addTearDown(controller.shutdown);
    await show(tester, controller);

    await tester.tap(find.text('下载模型'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('三个源都没下成'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('选中文件后列出分段、时间戳与语言，并显示统计', (WidgetTester tester) async {
    final TranscribeController controller = build(
      decoder: FakeDecoder(samples: 2 * kSampleRate),
    );
    addTearDown(controller.shutdown);
    await show(tester, controller, pickFile: () async => '/tmp/yue.wav');

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(find.text('呢几个字都表达唔到'), findsOneWidget);
    expect(find.textContaining('00:00:00.000 → 00:00:02.000'), findsOneWidget);
    expect(find.text('yue.wav'), findsOneWidget);
    // 底部统计与状态行都会提到段数，这里只认底部那条完整统计
    expect(find.textContaining('1 段　音频 2.00s'), findsOneWidget);
    expect(find.text('识别完成：1 段'), findsOneWidget);
  });

  testWidgets('解码失败时把中文说明显示在错误框里', (WidgetTester tester) async {
    final TranscribeController controller = build(
      decodeFailure: const AudioDecodeException('系统无法解码该格式（mkv / webm 需先转码）'),
    );
    addTearDown(controller.shutdown);
    await show(tester, controller, pickFile: () async => '/tmp/a.mkv');

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(find.textContaining('mkv / webm 需先转码'), findsOneWidget);
    expect(find.text('解码失败'), findsOneWidget);
    expect(find.text('选一个音频或视频文件开始'), findsOneWidget);
  });

  testWidgets('导出：选格式 → 交给保存器 → 提示落地位置', (WidgetTester tester) async {
    final List<(String, String)> saved = <(String, String)>[];
    final TranscribeController controller = build(text: '开饭时间早上9点至下午5点。');
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      pickFile: () async => '/tmp/zh.wav',
      saveFile: (String name, String content) async {
        saved.add((name, content));
        return '/Users/me/Desktop/$name';
      },
    );

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }

    await tester.tap(find.text('导出字幕'));
    await tester.pumpAndSettle();
    expect(find.text('导出格式'), findsOneWidget);
    // 四种格式都在
    for (final String format in <String>['SRT', 'VTT', 'JSON', 'TXT']) {
      expect(find.textContaining('$format — '), findsOneWidget);
    }

    await tester.tap(find.textContaining('SRT — '));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.$1, 'zh.srt'); // 文件名跟着音频名走
    expect(saved.single.$2, contains('00:00:00,000 --> 00:00:01,000'));
    expect(saved.single.$2, contains('开饭时间早上9点至下午5点。'));
    expect(
      find.textContaining('已导出到 /Users/me/Desktop/zh.srt'),
      findsOneWidget,
    );
  });

  testWidgets('没有结果时导出按钮是禁用的', (WidgetTester tester) async {
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(tester, controller);

    final Finder button = find.ancestor(
      of: find.text('导出字幕'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
  });

  testWidgets('配置 API Key 后可以把识别结果翻译为中文', (WidgetTester tester) async {
    final _FakeSecretStore secrets = _FakeSecretStore()
      ..values[kTranslationApiKeyStorageKey] = 'test-key';
    final AppSettingsRepository settings = AppSettingsRepository(
      preferences: _FakePreferenceStore(),
      secrets: TranslationSecrets(store: secrets),
    );
    final _FakeTranslationProvider provider = _FakeTranslationProvider();
    final TranscribeController controller = build(text: 'hello');
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      settings: settings,
      translationProviderFactory: (_) => provider,
      pickFile: () async => '/tmp/en.wav',
    );

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('translateSubtitle')));
    await tester.pumpAndSettle();

    expect(provider.calls, 1);
    expect(controller.result?.segments.single.translation, '译文：hello');
    expect(find.text('译文：hello'), findsOneWidget);
    expect(find.text('翻译完成：1 段'), findsOneWidget);
  });

  testWidgets('没有 API Key 时翻译入口提示先配置设置', (WidgetTester tester) async {
    final AppSettingsRepository settings = AppSettingsRepository(
      preferences: _FakePreferenceStore(),
      secrets: TranslationSecrets(store: _FakeSecretStore()),
    );
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(
      tester,
      controller,
      settings: settings,
      pickFile: () async => '/tmp/en.wav',
    );

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('translateSubtitle')));
    await tester.pump();

    expect(find.text('请先在设置中保存第三方翻译 API Key'), findsOneWidget);
  });

  testWidgets('切换语言后新识别结果用新语言', (WidgetTester tester) async {
    final TranscribeController controller = build();
    addTearDown(controller.shutdown);
    await show(tester, controller, pickFile: () async => '/tmp/a.wav');

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('粤语').last);
    await tester.pumpAndSettle();
    expect(controller.language, 'yue');

    await tester.tap(find.text('选择音频/视频'));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(controller.result?.segments.single.language, 'yue');
    expect(find.text('粤语'), findsWidgets); // 下拉里选中的 + 分段行里的语言标签
  });
}

class _FakeTranslationProvider implements TranslationProvider {
  int calls = 0;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) async {
    calls++;
    return texts.map((String text) => '译文：$text').toList();
  }
}

class _FakePreferenceStore implements PreferenceStore {
  @override
  Future<String?> readString(String key) async => null;

  @override
  Future<bool?> readBool(String key) async => null;

  @override
  Future<int?> readInt(String key) async => null;

  @override
  Future<double?> readDouble(String key) async => null;

  @override
  Future<void> writeString(String key, String value) async {}

  @override
  Future<void> writeBool(String key, bool value) async {}

  @override
  Future<void> writeInt(String key, int value) async {}

  @override
  Future<void> writeDouble(String key, double value) async {}
}

class _FakeSecretStore implements SecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
