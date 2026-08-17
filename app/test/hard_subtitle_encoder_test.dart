import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_style.dart';
import 'package:vsasr_app/src/video/hard_subtitle_encoder.dart';

void main() {
  test('ASS 字幕保留说话人、双语文本、样式和时间戳', () {
    const TranscriptionResult result = TranscriptionResult(
      duration: 3,
      segments: <Segment>[
        Segment(
          text: '{原文}',
          translation: '译文',
          speaker: 'Alice',
          start: 0.5,
          end: 2.345,
          index: 0,
        ),
      ],
    );
    final String ass = buildAssSubtitle(
      result,
      const SubtitleStyle(
        fontSize: 24,
        textColor: 0xFFFF0000,
        backgroundColor: 0x80000000,
        position: SubtitlePosition.top,
      ),
    );

    expect(ass, contains('Style: Default,Arial,24.0'));
    expect(ass, contains(',8,40,40,20,1'));
    expect(
      ass,
      contains(
        r'Dialogue: 0,0:00:00.50,0:00:02.35,Default,,0,0,0,,【Alice】\N\{原文\}\N译文',
      ),
    );
  });

  test('编码器拒绝不存在输入、覆盖输入和非 mp4 输出', () async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'vsasr-hard-subtitle-test',
    );
    addTearDown(() async {
      if (workspace.existsSync()) await workspace.delete(recursive: true);
    });
    final String input = '${workspace.path}/input.mp4';
    File(input).writeAsStringSync('not a video');
    const TranscriptionResult result = TranscriptionResult(
      duration: 1,
      segments: <Segment>[Segment(text: '字幕', start: 0, end: 1)],
    );
    final FfmpegHardSubtitleEncoder encoder = FfmpegHardSubtitleEncoder(
      executable: 'ffmpeg-not-installed-for-test',
    );

    await expectLater(
      encoder.encode(
        inputPath: input,
        outputPath: input,
        result: result,
        style: const SubtitleStyle(),
      ),
      throwsA(isA<HardSubtitleEncodeException>()),
    );
    await expectLater(
      encoder.encode(
        inputPath: input,
        outputPath: '${workspace.path}/output.mov',
        result: result,
        style: const SubtitleStyle(),
      ),
      throwsA(isA<HardSubtitleEncodeException>()),
    );
  });
}
