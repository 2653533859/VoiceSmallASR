/// 播放位置与识别段之间的时间轴查询。
library;

import 'package:vsasr_app/src/asr/segment.dart';

/// 返回播放位置对应的字幕段；段尾时切换到下一段或空字幕。
Segment? activeSegment(Iterable<Segment> segments, Duration position) {
  final double seconds = position.inMicroseconds / Duration.microsecondsPerSecond;
  for (final Segment segment in segments) {
    if (seconds >= segment.start && seconds < segment.end) return segment;
  }
  return null;
}
