/// 真实 sherpa-onnx 说话人分离验收。
///
/// 默认跳过，不下载模型。运行时显式提供已经准备好的模型目录和官方测试 WAV：
///
/// ```bash
/// VSASR_SPEAKER_MODEL_DIR=/path/to/speaker-models \
/// VSASR_SPEAKER_TEST_AUDIO=/path/to/0-four-speakers-zh.wav \
/// flutter test integration_test/speaker_diarization_acceptance_test.dart -d macos
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vsasr_app/src/asr/speaker_diarization.dart';
import 'package:vsasr_app/src/asr/speaker_diarization_model_manager.dart';
import 'package:vsasr_app/src/audio/wav.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('真实模型输出有效的说话人时间段', () async {
    final String? root = Platform.environment['VSASR_SPEAKER_MODEL_DIR']
        ?.trim();
    final String? audio = Platform.environment['VSASR_SPEAKER_TEST_AUDIO']
        ?.trim();
    if (root == null || root.isEmpty || audio == null || audio.isEmpty) {
      markTestSkipped('未提供 VSASR_SPEAKER_MODEL_DIR 或 VSASR_SPEAKER_TEST_AUDIO');
      return;
    }
    final SpeakerDiarizationModelManager manager =
        SpeakerDiarizationModelManager(root: root);
    final SpeakerDiarizationModelPaths paths = await manager.resolvePaths();
    expect(paths.exists, isTrue, reason: '说话人模型未就绪：${paths.root}');
    await manager.verifyIntegrity(paths);
    final Float32List samples = decodeWavToModelInput(
      await File(audio).readAsBytes(),
    );
    final List<SpeakerDiarizationSpan> spans =
        await runOfflineSpeakerDiarization(
          samples,
          paths,
          const SpeakerDiarizationOptions(numClusters: 4),
        );

    expect(spans, isNotEmpty);
    expect(
      spans.every(
        (SpeakerDiarizationSpan span) =>
            span.speaker >= 0 && span.end > span.start,
      ),
      isTrue,
    );
  });
}
