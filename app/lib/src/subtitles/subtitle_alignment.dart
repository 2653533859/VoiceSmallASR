/// 基于语音活动区间生成保守的字幕分段校时建议。
library;

import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

class SpeechTimeRange {
  const SpeechTimeRange({required this.start, required this.end});

  final double start;
  final double end;
}

class SubtitleAlignmentProposal {
  const SubtitleAlignmentProposal({
    required this.result,
    required this.meanAdjustmentSeconds,
    required this.maxAdjustmentSeconds,
  });

  final TranscriptionResult result;
  final double meanAdjustmentSeconds;
  final double maxAdjustmentSeconds;
}

/// 按顺序将字幕边界对齐到 VAD 语音区间。
///
/// 当前策略刻意保守：字幕与语音区间必须一一对应，任何边界移动超过
/// [maxAdjustmentSeconds]、区间无效或结果时间轴不合法时都返回 `null`。
SubtitleAlignmentProposal? proposeVadSubtitleAlignment(
  TranscriptionResult source,
  List<SpeechTimeRange> speechRanges, {
  double maxAdjustmentSeconds = 2.0,
}) {
  final List<Segment> segments = source.segments;
  if (!maxAdjustmentSeconds.isFinite ||
      maxAdjustmentSeconds <= 0 ||
      segments.isEmpty ||
      segments.length != speechRanges.length) {
    return null;
  }

  final List<Segment> aligned = <Segment>[];
  double adjustmentSum = 0;
  double largestAdjustment = 0;
  for (int index = 0; index < segments.length; index++) {
    final Segment segment = segments[index];
    final SpeechTimeRange range = speechRanges[index];
    if (!range.start.isFinite ||
        !range.end.isFinite ||
        range.start < 0 ||
        range.end <= range.start ||
        range.end > source.duration) {
      return null;
    }
    final double startAdjustment = (range.start - segment.start).abs();
    final double endAdjustment = (range.end - segment.end).abs();
    if (startAdjustment > maxAdjustmentSeconds ||
        endAdjustment > maxAdjustmentSeconds) {
      return null;
    }
    adjustmentSum += startAdjustment + endAdjustment;
    if (startAdjustment > largestAdjustment) {
      largestAdjustment = startAdjustment;
    }
    if (endAdjustment > largestAdjustment) largestAdjustment = endAdjustment;
    aligned.add(
      segment.copyWith(
        start: range.start,
        end: range.end,
        words: _remapWords(segment, range),
      ),
    );
  }

  if (validateSubtitleTimeline(aligned, duration: source.duration).isNotEmpty) {
    return null;
  }
  return SubtitleAlignmentProposal(
    result: source.copyWith(segments: aligned),
    meanAdjustmentSeconds: adjustmentSum / (segments.length * 2),
    maxAdjustmentSeconds: largestAdjustment,
  );
}

List<Word> _remapWords(Segment segment, SpeechTimeRange range) {
  if (segment.words.isEmpty) return const <Word>[];
  final double originalDuration = segment.end - segment.start;
  if (originalDuration <= 0) return const <Word>[];
  final double scale = (range.end - range.start) / originalDuration;
  return segment.words
      .map((Word word) {
        final double start =
            range.start +
            (word.start - segment.start).clamp(0, originalDuration).toDouble() *
                scale;
        final double end =
            range.start +
            (word.end - segment.start).clamp(0, originalDuration).toDouble() *
                scale;
        return Word(
          text: word.text,
          start: start,
          end: end < start ? start : end,
        );
      })
      .toList(growable: false);
}
