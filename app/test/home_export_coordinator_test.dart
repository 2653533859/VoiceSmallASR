import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/ui/batch_transcription_controller.dart';
import 'package:vsasr_app/src/ui/home_export_coordinator.dart';

void main() {
  const TranscriptionResult result = TranscriptionResult(
    language: 'en',
    duration: 1,
    segments: <Segment>[
      Segment(
        text: 'hello',
        start: 0,
        end: 1,
        words: <Word>[Word(text: 'hello', start: 0, end: 1)],
        language: 'en',
        index: 0,
      ),
    ],
  );

  test('批量导出为重名文件生成安全且不冲突的文件名', () async {
    final List<String> names = <String>[];
    final HomeBatchExportSummary summary = await HomeExportCoordinator()
        .exportBatch(
          items: <BatchItem>[
            BatchItem(
              path: '/tmp/episode.mp4',
              status: BatchItemStatus.completed,
              result: result,
            ),
            BatchItem(
              path: '/tmp/episode.mkv',
              status: BatchItemStatus.completed,
              result: result,
            ),
          ],
          format: 'SRT',
          saveFile:
              (
                String name,
                String content, {
                required String dialogTitle,
              }) async {
                names.add(name);
                expect(content, contains('hello'));
                expect(dialogTitle, startsWith('批量导出'));
                return '/tmp/$name';
              },
        );

    expect(summary.totalCount, 2);
    expect(summary.exportedCount, 2);
    expect(summary.failedCount, 0);
    expect(summary.cancelled, isFalse);
    expect(names, <String>['episode.srt', 'episode-2.srt']);
  });

  test('用户取消一个保存后停止剩余导出', () async {
    int calls = 0;
    final HomeBatchExportSummary summary = await HomeExportCoordinator()
        .exportBatch(
          items: <BatchItem>[
            BatchItem(
              path: '/tmp/one.wav',
              status: BatchItemStatus.completed,
              result: result,
            ),
            BatchItem(
              path: '/tmp/two.wav',
              status: BatchItemStatus.completed,
              result: result,
            ),
          ],
          format: 'vtt',
          saveFile:
              (
                String name,
                String content, {
                required String dialogTitle,
              }) async {
                calls++;
                return calls == 1 ? '/tmp/$name' : null;
              },
        );

    expect(summary.exportedCount, 1);
    expect(summary.totalCount, 2);
    expect(summary.cancelled, isTrue);
    expect(calls, 2);
  });

  test('拒绝不支持的导出格式', () async {
    await expectLater(
      HomeExportCoordinator().exportBatch(
        items: <BatchItem>[],
        format: 'xml',
        saveFile: (
          String name,
          String content, {
          required String dialogTitle,
        }) async => null,
      ),
      throwsArgumentError,
    );
  });
}
