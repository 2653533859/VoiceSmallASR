/// 实时字幕页签的 widget 测试：页签切换、录音按钮状态、
/// 临时结果原地刷新、导出与错误提示。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/microphone.dart';
import 'package:vsasr_app/src/ui/home_page.dart';
import 'package:vsasr_app/src/ui/live_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

import 'support/fake_asr.dart';

void main() {
  late Directory workspace;
  late FakeTranscriber transcriber;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('vsasr_live_ui_test');
    writeFakeModel(workspace.path);
    transcriber = FakeTranscriber();
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  /// 只推进有限帧，避免页面或插件留下的常驻动画让 pumpAndSettle 永不返回。
  Future<void> pumpUi(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 装好「文件转写 + 实时字幕」两个控制器，直接落在实时字幕页签上。
  Future<(LiveController, FakeMicrophone)> show(
    WidgetTester tester, {
    FakeMicrophone? mic,
    SaveFile? saveFile,
  }) async {
    final FakeMicrophone microphone = mic ?? FakeMicrophone();
    final TranscribeController controller = TranscribeController(
      decoder: FakeDecoder(),
      models: ModelManager(root: workspace.path),
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => transcriber,
    );
    final LiveController live = LiveController(
      provideWorker: () async => transcriber,
      languageOf: () => controller.language,
      mic: microphone,
    );
    addTearDown(() async {
      await live.shutdown();
      await controller.shutdown();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(controller: controller, live: live, saveFile: saveFile),
      ),
    );
    await tester.pump(); // refreshModel
    await tester.pump();
    await tester.tap(find.text('实时字幕'));
    await pumpUi(tester);
    return (live, microphone);
  }

  /// 让那些只在真实事件循环上完成的 Future（Stream 的 close/cancel）走几轮。
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
  }

  /// 点「停止」并等它真的收完尾。
  ///
  /// 收尾要等麦克风流关闭、识别会话关闭、两个订阅取消 —— 这些 Future 只在真实
  /// 事件循环上完成，`pump()` 的 fake async 推不动它们，因此得借 [runAsync] 走几轮。
  Future<void> stopRecording(WidgetTester tester) async {
    await tester.tap(find.text('停止'));
    await settle(tester);
  }

  testWidgets('模型就绪后有两个页签，实时字幕页给出空态提示', (WidgetTester tester) async {
    await show(tester);

    expect(find.text('文件转写'), findsOneWidget);
    expect(find.text('实时字幕'), findsOneWidget);
    expect(find.text('开始录音'), findsOneWidget);
    expect(find.text('点「开始录音」，边说边出字幕'), findsOneWidget);
  });

  testWidgets('点开始录音后按钮变成停止，再点停止回到初始态', (WidgetTester tester) async {
    final (LiveController live, _) = await show(tester);

    await tester.tap(find.text('开始录音'));
    await pumpUi(tester);

    expect(live.recording, isTrue);
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('开始录音'), findsNothing);
    expect(find.textContaining('录音中'), findsOneWidget);

    await stopRecording(tester);

    expect(find.text('开始录音'), findsOneWidget);
    expect(find.text('停止'), findsNothing);
  });

  testWidgets('临时结果原地刷新，定稿后带序号与时间戳落在列表里', (WidgetTester tester) async {
    await show(tester);
    await tester.tap(find.text('开始录音'));
    await pumpUi(tester);

    final FakeLiveSession session = transcriber.live!;
    session.emit(
      const Segment(text: '今日天', start: 0.0, end: 1.0, isFinal: false),
    );
    await pumpUi(tester);
    // 临时结果带省略号，提示这行还没定
    expect(find.text('今日天 …'), findsOneWidget);

    session.emit(
      const Segment(text: '今日天气', start: 0.0, end: 1.4, isFinal: false),
    );
    await pumpUi(tester);
    expect(find.text('今日天 …'), findsNothing); // 原地替换，不是追加
    expect(find.text('今日天气 …'), findsOneWidget);

    session.emit(
      const Segment(text: '今日天气几好。', start: 0.0, end: 1.8, index: 0),
    );
    await pumpUi(tester);
    expect(find.text('今日天气几好。'), findsOneWidget);
    expect(find.textContaining(' …'), findsNothing);
    expect(find.text('1'), findsOneWidget); // 序号从 1 显示
    expect(find.text('00:00:00.000 → 00:00:01.800'), findsOneWidget);
  });

  testWidgets('录音时禁用语言下拉：切语言会把正在用的会话拆掉', (WidgetTester tester) async {
    await show(tester);
    final Finder picker = find.byType(DropdownButton<String>);
    expect(tester.widget<DropdownButton<String>>(picker).onChanged, isNotNull);

    await tester.tap(find.text('开始录音'));
    await pumpUi(tester);
    expect(tester.widget<DropdownButton<String>>(picker).onChanged, isNull);

    await stopRecording(tester);
    expect(tester.widget<DropdownButton<String>>(picker).onChanged, isNotNull);
  });

  testWidgets('没有定稿结果时导出与清空都是禁用的', (WidgetTester tester) async {
    await show(tester);

    OutlinedButton buttonOf(String label) => tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(buttonOf('导出字幕').onPressed, isNull);
    expect(buttonOf('清空').onPressed, isNull);
  });

  testWidgets('导出：文件名固定为 live，内容只含定稿句', (WidgetTester tester) async {
    final List<(String, String)> saved = <(String, String)>[];
    await show(
      tester,
      saveFile: (String name, String content) async {
        saved.add((name, content));
        return '/Users/me/Desktop/$name';
      },
    );

    await tester.tap(find.text('开始录音'));
    await pumpUi(tester);
    final FakeLiveSession session = transcriber.live!;
    session.emit(const Segment(text: '第一句。', start: 0.0, end: 1.0, index: 0));
    session.emit(
      const Segment(text: '没定的半句', start: 1.2, end: 1.6, isFinal: false),
    );
    await pumpUi(tester);
    await stopRecording(tester);

    await tester.tap(find.text('导出字幕'));
    await pumpUi(tester);
    await tester.tap(find.textContaining('SRT — '));
    await pumpUi(tester);

    expect(saved.single.$1, 'live.srt');
    expect(saved.single.$2, contains('第一句。'));
    expect(saved.single.$2, isNot(contains('没定的半句')));
    expect(
      find.textContaining('已导出到 /Users/me/Desktop/live.srt'),
      findsOneWidget,
    );
  });

  testWidgets('清空把列表和状态一起收掉', (WidgetTester tester) async {
    await show(tester);
    await tester.tap(find.text('开始录音'));
    await pumpUi(tester);
    transcriber.live!.emit(
      const Segment(text: '第一句。', start: 0.0, end: 1.0, index: 0),
    );
    await pumpUi(tester);
    await stopRecording(tester);

    await tester.tap(find.text('清空'));
    await pumpUi(tester);

    expect(find.text('第一句。'), findsNothing);
    expect(find.text('点「开始录音」，边说边出字幕'), findsOneWidget);
  });

  testWidgets('没有麦克风权限时把中文说明显示在错误框里', (WidgetTester tester) async {
    await show(
      tester,
      mic: FakeMicrophone(
        failure: const MicrophoneException('没有麦克风权限，请在系统设置里允许'),
      ),
    );

    await tester.tap(find.text('开始录音'));
    // 开录失败后同样要收尾（会话已经开出来了），所以不能只 pumpAndSettle
    await settle(tester);

    expect(find.text('没有麦克风权限，请在系统设置里允许'), findsOneWidget);
    expect(find.text('开始录音'), findsOneWidget); // 回到可重试的状态
  });
}
