/// 使用真实 macOS 音轨解码和 Silero VAD 评估保守分段校时建议。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/vad_session.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/subtitles/subtitle_alignment.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实视频的 VAD 分段校时能纠正错位或安全拒绝', (WidgetTester tester) async {
    await _showStatus(tester, '正在加载字幕校时验收环境…');
    final String path =
        Platform.environment['VSASR_ALIGNMENT_VIDEO'] ??
        '/private/tmp/vsasr_10min_speech_acceptance.mp4';
    expect(File(path).existsSync(), isTrue, reason: '缺少验收视频：$path');

    final ModelManager models = ModelManager();
    final ModelPaths paths = await models.ensure(allowDownload: false);
    final AsrConfig config = AsrConfig();
    const PlatformAudioDecoder decoder = PlatformAudioDecoder();
    final TranscribeController controller = TranscribeController(
      decoder: decoder,
      models: models,
      config: config,
    );
    final VadSession vad = _createVad(config, paths.vadModel);
    addTearDown(controller.shutdown);
    addTearDown(vad.dispose);

    await _showStatus(tester, '正在识别自然语音片段…');
    final TranscriptionResult reference = await controller
        .transcribeVideoStream(path);
    await _showStatus(tester, '正在检测语音边界…');
    final List<SpeechTimeRange> speechRanges = <SpeechTimeRange>[];
    await for (final DecodedAudioChunk chunk in decoder.decodeFileChunks(
      path,
    )) {
      vad.accept(chunk.samples);
      _drainVad(vad, speechRanges);
    }
    vad.flush();
    _drainVad(vad, speechRanges);

    expect(reference.segments, isNotEmpty);
    const double injectedOffset = 0.75;
    String outcome;
    double? beforeError;
    double? afterError;
    if (speechRanges.length == reference.segments.length) {
      final TranscriptionResult shifted = reference.copyWith(
        segments: reference.segments
            .map((Segment segment) => _shiftSegment(segment, injectedOffset))
            .toList(growable: false),
      );
      final SubtitleAlignmentProposal? proposal = proposeVadSubtitleAlignment(
        shifted,
        speechRanges,
        maxAdjustmentSeconds: 1,
      );
      expect(proposal, isNotNull);
      beforeError = _meanBoundaryError(shifted.segments, speechRanges);
      afterError = _meanBoundaryError(proposal!.result.segments, speechRanges);
      expect(beforeError, closeTo(injectedOffset, 1e-6));
      expect(afterError, lessThan(1e-9));
      expect(proposal.maxAdjustmentSeconds, closeTo(injectedOffset, 1e-6));
      outcome = 'aligned';
    } else {
      expect(proposeVadSubtitleAlignment(reference, speechRanges), isNull);
      outcome = 'rejected_count_mismatch';
    }

    // ignore: avoid_print
    print(
      'ALIGNMENT_METRICS ${jsonEncode(<String, Object?>{'duration_seconds': reference.duration, 'subtitle_segments': reference.segments.length, 'vad_segments': speechRanges.length, 'outcome': outcome, 'injected_offset_seconds': speechRanges.length == reference.segments.length ? injectedOffset : null, 'before_mean_boundary_error_seconds': beforeError, 'after_mean_boundary_error_seconds': afterError})}',
    );
    await _showStatus(tester, '字幕校时验收完成');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> _showStatus(WidgetTester tester, String message) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(message, style: const TextStyle(fontSize: 24)),
        ),
      ),
    ),
  );
  await tester.pump();
}

VadSession _createVad(AsrConfig config, String modelPath) {
  so.initBindings();
  return VadSession.create(config.vad, modelPath);
}

void _drainVad(VadSession vad, List<SpeechTimeRange> output) {
  for (final speech in vad.drain()) {
    output.add(
      SpeechTimeRange(
        start: speech.start,
        end: speech.start + speech.samples.length / kSampleRate,
      ),
    );
  }
}

Segment _shiftSegment(Segment segment, double seconds) => segment.copyWith(
  start: segment.start + seconds,
  end: segment.end + seconds,
  words: segment.words
      .map(
        (Word word) => Word(
          text: word.text,
          start: word.start + seconds,
          end: word.end + seconds,
        ),
      )
      .toList(growable: false),
);

double _meanBoundaryError(
  List<Segment> segments,
  List<SpeechTimeRange> ranges,
) {
  double total = 0;
  for (int index = 0; index < segments.length; index++) {
    total += (segments[index].start - ranges[index].start).abs();
    total += (segments[index].end - ranges[index].end).abs();
  }
  return total / (segments.length * 2);
}
