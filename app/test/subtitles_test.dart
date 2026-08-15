import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

void main() {
  const Segment segment = Segment(
    text: 'Hello',
    start: 0.0,
    end: 1.25,
    language: 'en',
    index: 0,
    translation: '你好',
  );

  test('SRT 默认输出原文和译文两行，可切换译文在前或关闭双语', () {
    const TranscriptionResult result = TranscriptionResult(
      segments: <Segment>[segment],
    );

    expect(
      toSrt(result.segments),
      '1\n00:00:00,000 --> 00:00:01,250\nHello\n你好\n\n',
    );
    expect(
      toSrt(result.segments, translationFirst: true),
      '1\n00:00:00,000 --> 00:00:01,250\n你好\nHello\n\n',
    );
    expect(
      toSrt(result.segments, bilingual: false),
      '1\n00:00:00,000 --> 00:00:01,250\nHello\n\n',
    );
  });

  test('VTT 和 TXT 都保留双语顺序，空白译文不会产生空行', () {
    const TranscriptionResult result = TranscriptionResult(
      segments: <Segment>[
        segment,
        Segment(text: 'Only source', start: 1.25, end: 2.0, translation: '  '),
      ],
    );

    expect(
      toVtt(result.segments),
      'WEBVTT\n\n'
      '00:00:00.000 --> 00:00:01.250\n'
      'Hello\n'
      '你好\n\n'
      '00:00:01.250 --> 00:00:02.000\n'
      'Only source\n\n',
    );
    expect(toTxt(result.segments), 'Hello\n你好\nOnly source\n');
    expect(toTxt(result.segments, bilingual: false), 'Hello\nOnly source\n');
  });

  test('带译文的长段不切分，避免原文与译文时间边界错位', () {
    final Segment longSegment = Segment(
      text: 'a' * 60,
      start: 2.0,
      end: 10.0,
      translation: '一整条译文',
    );

    final List<Cue> cues = buildCues(
      <Segment>[longSegment],
      maxChars: 10,
      maxDuration: 2.0,
    );

    expect(cues, hasLength(1));
    expect(cues.single.text, 'a' * 60);
    expect(cues.single.translation, '一整条译文');
    expect(cues.single.start, 2.0);
    expect(cues.single.end, 10.0);
  });

  test('JSON 导出保留 Segment.translation，其他格式仍走字幕渲染', () {
    const TranscriptionResult result = TranscriptionResult(
      language: 'en',
      segments: <Segment>[segment],
    );

    final String json = renderSubtitles(result, 'json');
    expect(json, contains('"translation": "你好"'));
    expect(renderSubtitles(result, 'srt'), contains('Hello\n你好'));
    expect(() => renderSubtitles(result, 'ass'), throwsArgumentError);
  });
}
