/// VSASR_RANGE_VIDEO 指向含语音的本地 MP4，用真实解码器和模型验证选区识别。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/project/project_file.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('真实MP4选区解码、识别、替换及撤销', () async {
    final path = Platform.environment['VSASR_RANGE_VIDEO'];
    expect(
      path,
      isNotNull,
      reason: '设置 VSASR_RANGE_VIDEO，素材需至少 8 秒且 1–8 秒含日语语音',
    );
    expect(File(path!).existsSync(), isTrue);
    const source = TranscriptionResult(
      duration: 8,
      segments: [
        Segment(text: '选区外', start: 0, end: 1, translation: 'keep'),
        Segment(text: '待重识别', start: 1, end: 8, translation: 'old'),
      ],
    );
    final controller = TranscribeController(offlineMode: true);
    addTearDown(controller.shutdown);
    await controller.loadProject(
      VsasrProject(mediaPath: path, config: AsrConfig(), result: source),
    );
    final segments = await controller.previewRange(
      start: 1,
      end: 8,
      config: AsrConfig(language: 'ja', inputGainDb: 6),
    );
    expect(segments, isNotEmpty);
    expect(
      segments.every((s) => s.start >= 1 && s.end <= 8 && s.language == 'ja'),
      isTrue,
    );
    expect(controller.result, same(source));
    final editor = SubtitleEditorController(initial: source);
    addTearDown(editor.dispose);
    editor.replaceRange(1, 8, segments);
    expect(editor.result.segments.first.translation, 'keep');
    editor.undo();
    expect(editor.result.segments.last.translation, 'old');
    // ignore: avoid_print
    print(
      'MP4选区识别：${segments.map((s) => '${s.start}-${s.end}: ${s.text}').join('\n')}',
    );
  });
}
