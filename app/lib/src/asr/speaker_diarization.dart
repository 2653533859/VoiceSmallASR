/// 离线说话人分离：把 sherpa-onnx 的时间段结果映射到字幕段。
///
/// 原生 diarizer 放在独立 isolate 中运行，避免同步 FFI 阻塞 Flutter UI。
/// 这一层只暴露项目自己的纯 Dart 数据类型，界面和项目文件不依赖 sherpa 类型。
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/speaker_diarization_model_manager.dart';

/// sherpa-onnx 聚类后的一段说话人时间范围。
class SpeakerDiarizationSpan {
  const SpeakerDiarizationSpan({
    required this.start,
    required this.end,
    required this.speaker,
  });

  final double start;
  final double end;
  final int speaker;

  double get duration => end > start ? end - start : 0.0;
}

/// diarizer 的运行参数。
///
/// [numClusters] 为 -1 时自动估计人数；设置为正数时固定人数。
/// [threshold] 越高，自动聚类得到的说话人越少，和 sherpa-onnx 的语义一致。
class SpeakerDiarizationOptions {
  const SpeakerDiarizationOptions({
    this.numClusters = -1,
    this.threshold = 0.9,
    this.minDurationOn = 0.2,
    this.minDurationOff = 0.5,
    this.numThreads = 1,
    this.provider = 'cpu',
  });

  final int numClusters;
  final double threshold;
  final double minDurationOn;
  final double minDurationOff;
  final int numThreads;
  final String provider;

  void validate() {
    if (numClusters < -1 || numClusters == 0) {
      throw ArgumentError.value(numClusters, 'numClusters', '必须为 -1 或正整数');
    }
    if (!threshold.isFinite || threshold <= 0) {
      throw ArgumentError.value(threshold, 'threshold', '必须是大于 0 的有限数字');
    }
    if (!minDurationOn.isFinite || minDurationOn < 0) {
      throw ArgumentError.value(minDurationOn, 'minDurationOn', '必须是非负有限数字');
    }
    if (!minDurationOff.isFinite || minDurationOff < 0) {
      throw ArgumentError.value(minDurationOff, 'minDurationOff', '必须是非负有限数字');
    }
    if (numThreads <= 0) {
      throw ArgumentError.value(numThreads, 'numThreads', '必须是正整数');
    }
    if (provider.trim().isEmpty) {
      throw ArgumentError.value(provider, 'provider', '不能为空');
    }
  }
}

/// 可注入的后台说话人分离实现。
typedef SpeakerDiarizationRunner =
    Future<List<SpeakerDiarizationSpan>> Function(
      Float32List samples,
      SpeakerDiarizationModelPaths paths,
      SpeakerDiarizationOptions options,
    );

/// 使用 sherpa-onnx 的 offline speaker diarization API，在后台 isolate 执行。
Future<List<SpeakerDiarizationSpan>> runOfflineSpeakerDiarization(
  Float32List samples,
  SpeakerDiarizationModelPaths paths,
  SpeakerDiarizationOptions options,
) async {
  options.validate();
  return Isolate.run<List<SpeakerDiarizationSpan>>(
    () => _runOfflineSpeakerDiarization(samples, paths, options),
  );
}

List<SpeakerDiarizationSpan> _runOfflineSpeakerDiarization(
  Float32List samples,
  SpeakerDiarizationModelPaths paths,
  SpeakerDiarizationOptions options,
) {
  so.initBindings();
  final so.OfflineSpeakerDiarization diarizer = so.OfflineSpeakerDiarization(
    so.OfflineSpeakerDiarizationConfig(
      segmentation: so.OfflineSpeakerSegmentationModelConfig(
        pyannote: so.OfflineSpeakerSegmentationPyannoteModelConfig(
          model: paths.segmentationModel,
        ),
        numThreads: options.numThreads,
        debug: false,
        provider: options.provider,
      ),
      embedding: so.SpeakerEmbeddingExtractorConfig(
        model: paths.embeddingModel,
        numThreads: options.numThreads,
        debug: false,
        provider: options.provider,
      ),
      clustering: so.FastClusteringConfig(
        numClusters: options.numClusters,
        threshold: options.threshold,
      ),
      minDurationOn: options.minDurationOn,
      minDurationOff: options.minDurationOff,
    ),
  );
  try {
    if (diarizer.sampleRate != kSampleRate) {
      throw StateError(
        '说话人模型要求 ${diarizer.sampleRate} Hz，当前应用只支持 $kSampleRate Hz',
      );
    }
    return diarizer
        .process(samples: samples)
        .map(
          (so.OfflineSpeakerDiarizationSegment segment) =>
              SpeakerDiarizationSpan(
                start: segment.start,
                end: segment.end,
                speaker: segment.speaker,
              ),
        )
        .toList(growable: false);
  } finally {
    diarizer.free();
  }
}

/// 将说话人时间段按最大重叠时长映射到识别字幕段。
///
/// diarization 得到的是聚类编号，不是姓名，因此标签固定为
/// `SPEAKER_00`、`SPEAKER_01`……，用户可以在字幕校对页改成真实姓名。
TranscriptionResult applySpeakerDiarization(
  TranscriptionResult result,
  Iterable<SpeakerDiarizationSpan> spans,
) {
  final List<SpeakerDiarizationSpan> validSpans = spans
      .where(
        (SpeakerDiarizationSpan span) =>
            span.speaker >= 0 &&
            span.start.isFinite &&
            span.end.isFinite &&
            span.end > span.start,
      )
      .toList(growable: false);
  final List<Segment> labeled = result.segments
      .map((Segment segment) {
        if (segment.end <= segment.start) {
          return segment.copyWith(clearSpeaker: true);
        }
        double bestOverlap = 0.0;
        int? bestSpeaker;
        for (final SpeakerDiarizationSpan span in validSpans) {
          final double overlap = _overlap(
            segment.start,
            segment.end,
            span.start,
            span.end,
          );
          if (overlap > bestOverlap ||
              (overlap == bestOverlap &&
                  bestSpeaker != null &&
                  span.speaker < bestSpeaker)) {
            bestOverlap = overlap;
            bestSpeaker = span.speaker;
          }
        }
        if (bestSpeaker == null) {
          return segment.copyWith(clearSpeaker: true);
        }
        return segment.copyWith(
          speaker: _speakerLabel(bestSpeaker),
          clearSpeaker: false,
        );
      })
      .toList(growable: false);
  return result.copyWith(segments: labeled);
}

double _overlap(
  double firstStart,
  double firstEnd,
  double secondStart,
  double secondEnd,
) {
  final double start = firstStart > secondStart ? firstStart : secondStart;
  final double end = firstEnd < secondEnd ? firstEnd : secondEnd;
  return end > start ? end - start : 0.0;
}

String _speakerLabel(int speaker) =>
    'SPEAKER_${speaker.toString().padLeft(2, '0')}';
