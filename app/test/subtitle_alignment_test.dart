import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitle_alignment.dart';

void main() {
  const TranscriptionResult source = TranscriptionResult(
    duration: 5,
    language: 'ja',
    segments: <Segment>[
      Segment(
        text: '第一句',
        start: 0.5,
        end: 1.5,
        words: <Word>[Word(text: '第一句', start: 0.5, end: 1.5)],
        translation: '译文一',
      ),
      Segment(text: '第二句', start: 2.0, end: 3.0),
    ],
  );

  test('VAD 对齐建议更新分段和 token 时间并保留文本字段', () {
    final SubtitleAlignmentProposal? proposal = proposeVadSubtitleAlignment(
      source,
      const <SpeechTimeRange>[
        SpeechTimeRange(start: 0.8, end: 1.6),
        SpeechTimeRange(start: 2.2, end: 3.4),
      ],
    );

    expect(proposal, isNotNull);
    expect(proposal!.result.segments.first.start, 0.8);
    expect(proposal.result.segments.first.end, 1.6);
    expect(proposal.result.segments.first.words.single.start, 0.8);
    expect(proposal.result.segments.first.words.single.end, 1.6);
    expect(proposal.result.segments.first.translation, '译文一');
    expect(proposal.result.language, 'ja');
    expect(proposal.meanAdjustmentSeconds, closeTo(0.25, 1e-9));
    expect(proposal.maxAdjustmentSeconds, closeTo(0.4, 1e-9));
  });

  test('段数不一致、调整过大或对齐后重叠时拒绝建议', () {
    expect(
      proposeVadSubtitleAlignment(source, const <SpeechTimeRange>[
        SpeechTimeRange(start: 0.8, end: 1.6),
      ]),
      isNull,
    );
    expect(
      proposeVadSubtitleAlignment(source, const <SpeechTimeRange>[
        SpeechTimeRange(start: 3.0, end: 4.0),
        SpeechTimeRange(start: 4.0, end: 5.0),
      ]),
      isNull,
    );
    expect(
      proposeVadSubtitleAlignment(source, const <SpeechTimeRange>[
        SpeechTimeRange(start: 0.8, end: 2.4),
        SpeechTimeRange(start: 2.2, end: 3.4),
      ]),
      isNull,
    );
  });
}
