import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/speaker_diarization.dart';
import 'package:vsasr_app/src/asr/speaker_diarization_model_manager.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

void main() {
  test('按字幕段与 diarization 时间重叠最多的说话人标注', () {
    const TranscriptionResult result = TranscriptionResult(
      duration: 5,
      segments: <Segment>[
        Segment(text: '甲', start: 0, end: 1, index: 0),
        Segment(text: '乙', start: 1, end: 3, index: 1, translation: 'B'),
        Segment(text: '丙', start: 4, end: 4, index: 2),
      ],
    );
    final TranscriptionResult labeled = applySpeakerDiarization(
      result,
      const <SpeakerDiarizationSpan>[
        SpeakerDiarizationSpan(start: 0, end: 0.6, speaker: 1),
        SpeakerDiarizationSpan(start: 0.6, end: 2.5, speaker: 0),
        SpeakerDiarizationSpan(start: 2.5, end: 3.5, speaker: 1),
      ],
    );

    expect(labeled.segments[0].speaker, 'SPEAKER_01');
    expect(labeled.segments[1].speaker, 'SPEAKER_00');
    expect(labeled.segments[1].translation, 'B');
    expect(labeled.segments[2].speaker, isNull);
  });

  test('选项拒绝无效的已知人数和聚类阈值', () {
    expect(
      () => const SpeakerDiarizationOptions(numClusters: 0).validate(),
      throwsArgumentError,
    );
    expect(
      () => const SpeakerDiarizationOptions(threshold: 0).validate(),
      throwsArgumentError,
    );
  });

  test('控制器重新解码媒体并把分离结果写回项目', () async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'vsasr-speaker-test',
    );
    addTearDown(() async {
      if (workspace.existsSync()) await workspace.delete(recursive: true);
    });
    final SpeakerDiarizationModelPaths paths = SpeakerDiarizationModelPaths(
      root: workspace.path,
      segmentationModel: '${workspace.path}/segmentation.onnx',
      embeddingModel: '${workspace.path}/embedding.onnx',
    );
    final FakeSpeakerModelManager models = FakeSpeakerModelManager(paths);
    final List<SpeakerDiarizationOptions> seenOptions =
        <SpeakerDiarizationOptions>[];
    final TranscribeController controller = TranscribeController(
      decoder: FakeSpeakerDecoder(),
      speakerModels: models,
      diarize:
          (
            Float32List samples,
            SpeakerDiarizationModelPaths receivedPaths,
            SpeakerDiarizationOptions options,
          ) async {
            expect(samples, hasLength(16000));
            expect(receivedPaths.root, workspace.path);
            seenOptions.add(options);
            return const <SpeakerDiarizationSpan>[
              SpeakerDiarizationSpan(start: 0, end: 0.8, speaker: 2),
              SpeakerDiarizationSpan(start: 0.8, end: 1, speaker: 3),
            ];
          },
    );
    addTearDown(controller.dispose);
    controller.applyImportedResult(
      const TranscriptionResult(
        duration: 1,
        segments: <Segment>[Segment(text: '测试', start: 0, end: 1, index: 0)],
      ),
      mediaPath: '/tmp/test.wav',
    );

    await controller.diarizeCurrentResult(numClusters: 2);

    expect(models.calls, 1);
    expect(seenOptions.single.numClusters, 2);
    expect(controller.result?.segments.single.speaker, 'SPEAKER_02');
    expect(controller.statusText, '说话人标注完成：1 位');
    expect(controller.projectRevision, 2);
    expect(controller.errorText, isNull);
    expect(controller.stage, JobStage.idle);
  });

  test('取消说话人标注时保留原字幕', () async {
    final Directory workspace = Directory.systemTemp.createTempSync(
      'vsasr-speaker-cancel-test',
    );
    addTearDown(() async {
      if (workspace.existsSync()) await workspace.delete(recursive: true);
    });
    final Completer<List<SpeakerDiarizationSpan>> pending =
        Completer<List<SpeakerDiarizationSpan>>();
    final TranscribeController controller = TranscribeController(
      decoder: FakeSpeakerDecoder(),
      speakerModels: FakeSpeakerModelManager(
        SpeakerDiarizationModelPaths(
          root: workspace.path,
          segmentationModel: '${workspace.path}/segmentation.onnx',
          embeddingModel: '${workspace.path}/embedding.onnx',
        ),
      ),
      diarize: (_, _, _) => pending.future,
    );
    addTearDown(controller.dispose);
    const TranscriptionResult original = TranscriptionResult(
      duration: 1,
      segments: <Segment>[Segment(text: '保留', start: 0, end: 1, index: 0)],
    );
    controller.applyImportedResult(original, mediaPath: '/tmp/test.wav');

    final Future<void> task = controller.diarizeCurrentResult();
    await Future<void>.delayed(Duration.zero);
    expect(controller.stage, JobStage.diarizing);
    await controller.cancelCurrentTask();
    pending.complete(const <SpeakerDiarizationSpan>[]);
    await task;

    expect(controller.result?.segments.single.text, '保留');
    expect(controller.stage, JobStage.idle);
  });
}

class FakeSpeakerModelManager extends SpeakerDiarizationModelManager {
  FakeSpeakerModelManager(this.paths);

  final SpeakerDiarizationModelPaths paths;
  int calls = 0;

  @override
  Future<SpeakerDiarizationModelPaths> ensure({
    bool allowDownload = true,
    ModelProgress? progress,
  }) async {
    calls++;
    progress?.call('说话人分离模型就绪', 1, 1);
    return paths;
  }
}

class FakeSpeakerDecoder implements AudioDecoder {
  @override
  Future<Float32List> decodeFile(String path) async => Float32List(16000);
}
