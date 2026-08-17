import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_style.dart';
import 'package:vsasr_app/src/video/hard_subtitle_encoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('Android 编码器通过 MethodChannel 传递 SAF 输出和字幕样式', () async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'vsasr-android-hard-subtitle-test',
    );
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('vsasr/hard_subtitle'),
            null,
          );
      if (workspace.existsSync()) await workspace.delete(recursive: true);
    });
    final String input = '${workspace.path}/input.mp4';
    File(input).writeAsStringSync('placeholder');
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('vsasr/hard_subtitle'), (
          MethodCall call,
        ) async {
          calls.add(call);
          return null;
        });

    final List<double?> progress = <double?>[];
    await AndroidHardSubtitleEncoder().encode(
      inputPath: input,
      outputPath: 'content://com.example.documents/video.mp4',
      result: const TranscriptionResult(
        duration: 2,
        segments: <Segment>[
          Segment(
            text: '原文',
            translation: '译文',
            speaker: 'SPEAKER_00',
            start: 0,
            end: 1,
            index: 0,
          ),
        ],
      ),
      style: const SubtitleStyle(position: SubtitlePosition.top),
      onProgress: progress.add,
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'encode');
    final Map<Object?, Object?> arguments =
        calls.single.arguments as Map<Object?, Object?>;
    expect(arguments['inputPath'], input);
    expect(arguments['outputPath'], startsWith('content://'));
    expect(arguments['segments'], hasLength(1));
    expect((arguments['style'] as Map<Object?, Object?>)['position'], 'top');
    expect(progress, <double?>[0.0, 1.0]);
  });
}
