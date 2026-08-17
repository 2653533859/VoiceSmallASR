import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_editor_controller.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

void main() {
  TranscriptionResult sample() => const TranscriptionResult(
    duration: 4.0,
    language: 'en',
    segments: <Segment>[
      Segment(
        text: 'hello',
        start: 0.0,
        end: 1.0,
        words: <Word>[Word(text: 'hello', start: 0.0, end: 1.0)],
        translation: '你好',
      ),
      Segment(text: 'world', start: 1.0, end: 2.0),
    ],
  );

  test('修改文本会清除过期译文和 token 时间戳，并支持撤销重做', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    editor.updateSegment(0, text: 'hi');
    expect(editor.result.segments.first.text, 'hi');
    expect(editor.result.segments.first.translation, isNull);
    expect(editor.result.segments.first.words, isEmpty);
    expect(editor.canUndo, isTrue);

    editor.undo();
    expect(editor.result.segments.first.text, 'hello');
    expect(editor.result.segments.first.translation, '你好');
    editor.redo();
    expect(editor.result.segments.first.text, 'hi');
  });

  test('时间修改拒绝重叠、倒序和超出音频时长', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    expect(
      () => editor.updateSegment(1, start: 0.5),
      throwsA(isA<SubtitleEditException>()),
    );
    expect(
      () => editor.updateSegment(0, end: 5.0),
      throwsA(isA<SubtitleEditException>()),
    );
    expect(editor.result.segments[0].end, 1.0);
    expect(validateSubtitleTimeline(editor.result.segments, duration: editor.result.duration), isEmpty);
  });

  test('时间修改会清除过期 token 时间戳但保留译文', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    editor.updateSegment(0, start: 0.2);

    expect(editor.result.segments.first.words, isEmpty);
    expect(editor.result.segments.first.translation, '你好');
  });

  test('批量时间偏移会同步移动 token、保留译文并支持撤销', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    editor.shiftTimeOffset(0.5);

    expect(editor.result.segments.first.start, 0.5);
    expect(editor.result.segments.first.end, 1.5);
    expect(editor.result.segments.first.words.single.start, 0.5);
    expect(editor.result.segments.first.words.single.end, 1.5);
    expect(editor.result.segments.first.translation, '你好');
    expect(editor.result.segments[1].start, 1.5);
    editor.undo();
    expect(editor.result.segments.first.start, 0.0);
  });

  test('批量时间偏移越过时间轴边界时拒绝且不改变结果', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    expect(
      () => editor.shiftTimeOffset(-0.1),
      throwsA(isA<SubtitleEditException>()),
    );
    expect(editor.result.segments.first.start, 0.0);
    expect(editor.canUndo, isFalse);
  });

  test('搜索替换会更新所有字幕并清除过期译文与 token', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    final int replacements = editor.replaceText(
      query: 'o',
      replacement: 'O',
    );

    expect(replacements, 2);
    expect(editor.result.segments[0].text, 'hellO');
    expect(editor.result.segments[1].text, 'wOrld');
    expect(editor.result.segments.first.translation, isNull);
    expect(editor.result.segments.first.words, isEmpty);
    editor.undo();
    expect(editor.result.segments.first.text, 'hello');
  });

  test('搜索替换支持不区分大小写', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    expect(
      editor.replaceText(
        query: 'HELLO',
        replacement: '你好',
        caseSensitive: false,
      ),
      1,
    );
    expect(editor.result.segments.first.text, '你好');
  });

  test('搜索替换未命中或搜索内容为空时不污染撤销记录', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    expect(editor.replaceText(query: 'missing', replacement: 'x'), 0);
    expect(editor.canUndo, isFalse);
    expect(
      () => editor.replaceText(query: '', replacement: 'x'),
      throwsA(isA<SubtitleEditException>()),
    );
  });

  test('阅读速度检查返回超阈值字幕且不修改编辑结果', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    final List<SubtitleReadingSpeedIssue> issues =
        editor.checkReadingSpeed(maxCharactersPerSecond: 4.0);

    expect(issues, hasLength(2));
    expect(issues.first.index, 0);
    expect(issues.first.characters, 5);
    expect(issues.first.charactersPerSecond, closeTo(5.0, 1e-9));
    expect(editor.result.segments.first.text, 'hello');
    expect(editor.canUndo, isFalse);
  });

  test('阅读速度检查拒绝非正阈值', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    expect(
      () => editor.checkReadingSpeed(maxCharactersPerSecond: 0),
      throwsA(isA<SubtitleEditException>()),
    );
  });

  test('重复应用相同内容不会新增撤销记录', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    editor.updateSegment(0, text: ' hello ');

    expect(editor.canUndo, isFalse);
  });

  test('合并和拆分会重排序号，撤销后可恢复原列表', () {
    final SubtitleEditorController editor = SubtitleEditorController(initial: sample());

    editor.mergeSegments(0);
    expect(editor.result.length, 1);
    expect(editor.result.segments.single.text, 'hello world');
    expect(editor.result.segments.single.start, 0.0);
    expect(editor.result.segments.single.end, 2.0);

    editor.undo();
    expect(editor.result.length, 2);
    editor.splitSegment(0, characterOffset: 2, splitTime: 0.4);
    expect(editor.result.length, 3);
    expect(editor.result.segments.map((Segment segment) => segment.index), <int>[0, 1, 2]);
    expect(editor.result.segments[0].text, 'he');
    expect(editor.result.segments[1].text, 'llo');
  });

  test('导出前的时间轴校验拒绝重叠字幕', () {
    const TranscriptionResult invalid = TranscriptionResult(
      duration: 3.0,
      segments: <Segment>[
        Segment(text: 'a', start: 0.0, end: 2.0),
        Segment(text: 'b', start: 1.5, end: 3.0),
      ],
    );
    expect(
      () => renderSubtitles(invalid, 'srt'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
