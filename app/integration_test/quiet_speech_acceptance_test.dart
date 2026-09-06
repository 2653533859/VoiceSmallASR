/// 用模型自带日语样本验证显式语言及两条识别路径中的输入增益。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/transcription_worker.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('日文语言与小声增益贯通整段和流式识别', () async {
    final paths = await ModelManager().resolvePaths();
    final String audio = p.join(
      p.dirname(paths.asrModel),
      'test_wavs',
      'ja.wav',
    );
    expect(paths.exists, isTrue, reason: '必须已有真实模型');
    expect(File(audio).existsSync(), isTrue, reason: '必须已有日语样本');
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(
      audio,
    );
    // 人为衰减只验证管线，不代表真实耳语、噪声或所有小声素材。
    final Float32List quiet = Float32List.fromList(
      samples.map((x) => x * .5).toList(),
    );
    final worker = await TranscriptionWorker.start(
      config: AsrConfig(
        language: 'ja',
        inputGainDb: 6,
        vad: const VadConfig(
          threshold: .35,
          minSilenceDuration: .5,
          minSpeechDuration: .15,
        ),
      ),
      allowDownload: false,
    );
    addTearDown(worker.dispose);
    final TranscriptionResult whole = await worker.transcribe(quiet);
    expect(whole.text, allOf(contains('中学'), contains('弁当')));
    final session = await worker.startLive();
    final Future<List<Segment>> collecting = session.segments.toList();
    for (int offset = 0; offset < quiet.length; offset += 16000) {
      final int end = (offset + 16000).clamp(0, quiet.length);
      await session.accept(Float32List.sublistView(quiet, offset, end));
    }
    await session.finish();
    final List<Segment> finals = (await collecting)
        .where((s) => s.isFinal)
        .toList();
    final String text = finals.map((s) => s.text).join();
    expect(text, allOf(contains('中学'), contains('弁当')));
    expect(finals.every((s) => s.language == 'ja'), isTrue);
    expect(finals.last.end, lessThanOrEqualTo(quiet.length / 16000 + .05));
    // ignore: avoid_print
    print('日文小声预设：整段=${whole.text}；流式=$text');
  });
}
