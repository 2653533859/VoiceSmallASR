import 'dart:convert';

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

  test('可以导入带 BOM、无毫秒时间和标签的 SRT', () {
    const String content =
        '\uFEFF1\n'
        '00:00:01 --> 00:00:02,500\n'
        '<i>第一条</i>\n\n'
        '2\n'
        '00:00:03.000 --> 00:00:04\n'
        '第二条\n';

    final TranscriptionResult result = parseSubtitleText(
      content,
      format: 'srt',
    );

    expect(result.length, 2);
    expect(result.segments[0].text, '第一条');
    expect(result.segments[0].start, 1.0);
    expect(result.segments[0].end, 2.5);
    expect(result.segments[1].start, 3.0);
    expect(result.duration, 4.0);
  });

  test('可以导入 VTT cue 设置并清理标签', () {
    const String content =
        'WEBVTT\n\n'
        'intro\n'
        '00:00:00.500 --> 00:00:02.000 align:start position:10%\n'
        '<c.green>欢迎</c>\n';

    final TranscriptionResult result = parseSubtitleText(
      content,
      format: '.vtt',
    );

    expect(result.segments.single.text, '欢迎');
    expect(result.segments.single.start, 0.5);
    expect(result.segments.single.end, 2.0);
  });

  test('导入 JSON 会保留原有语言、时长和译文', () {
    const TranscriptionResult source = TranscriptionResult(
      language: 'en',
      duration: 2.0,
      segments: <Segment>[segment],
    );

    final TranscriptionResult result = parseSubtitleText(
      renderSubtitles(source, 'json'),
      format: 'json',
    );

    expect(result.language, 'en');
    expect(result.duration, 2.0);
    expect(result.segments.single.translation, '你好');
  });

  test('导入字幕会拒绝倒序或重叠时间轴', () {
    expect(
      () => parseSubtitleText(
        '1\n00:00:02,000 --> 00:00:01,000\n无效\n',
        format: 'srt',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parseSubtitleText(
        '1\n00:00:00,000 --> 00:00:02,000\n第一条\n\n'
        '2\n00:00:01,000 --> 00:00:03,000\n第二条\n',
        format: 'srt',
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => parseSubtitleText(
        jsonEncode(<String, Object?>{'schema': 'voicesmallasr.project'}),
        format: 'json',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
