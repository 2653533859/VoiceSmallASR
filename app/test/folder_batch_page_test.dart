import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/ui/folder_batch_controller.dart';
import 'package:vsasr_app/src/ui/folder_batch_page.dart';

void main() {
  testWidgets('处理期间返回主界面后任务继续完成', (tester) async {
    final _BackgroundLifecycleController controller =
        _BackgroundLifecycleController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => FilledButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => FolderBatchPage(
                  controller: controller,
                  pickDirectory: () async => null,
                ),
              ),
            ),
            child: const Text('打开文件夹任务'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开文件夹任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('folderStart')));
    await tester.pump();
    expect(controller.running, isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('打开文件夹任务'), findsOneWidget);
    expect(controller.running, isTrue);
    expect(controller.disposedByPage, isFalse);

    controller.complete();
    await tester.pump();
    expect(controller.running, isFalse);
  });

  for (final size in [const Size(390, 844), const Size(640, 480)]) {
    testWidgets('选择预览后开始，支持关闭翻译 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = Directory.systemTemp.createTempSync('folder_page_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/1.mp4').createSync();
      File('${dir.path}/2.mp4').createSync();
      File('${dir.path}/2.srt').writeAsStringSync('existing');
      int calls = 0;
      final controller = FolderBatchController(
        transcribe: (_) async {
          calls++;
          return const TranscriptionResult(
            segments: [Segment(text: '原文', start: 0, end: 1)],
          );
        },
        prepareTranslation: () async => throw StateError('不应请求翻译'),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: FolderBatchPage(
            controller: controller,
            pickDirectory: () async => dir.path,
          ),
        ),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('folderStart')))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<FilterChip>(find.byType(FilterChip)).selected,
        isTrue,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('folderPick')));
        while (controller.loading || controller.directory == null) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.textContaining('跳过 1'), findsOneWidget);
      await tester.tap(find.byType(FilterChip));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('folderStart')));
        while (controller.running) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.textContaining('完成 1'), findsOneWidget);
      expect(File('${dir.path}/1.srt').readAsStringSync(), contains('原文'));
      expect(File('${dir.path}/2.srt').readAsStringSync(), 'existing');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

class _BackgroundLifecycleController extends FolderBatchController {
  _BackgroundLifecycleController()
    : super(
        transcribe: (_) async => null,
        prepareTranslation: () async => null,
      );

  final Completer<void> _completion = Completer<void>();
  bool disposedByPage = false;

  @override
  bool get hasPending => true;

  @override
  Future<void> start({bool? translate}) async {
    running = true;
    notifyListeners();
    await _completion.future;
    running = false;
    notifyListeners();
  }

  void complete() => _completion.complete();

  @override
  void dispose() {
    disposedByPage = true;
    super.dispose();
  }
}
