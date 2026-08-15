/// 字幕与文本导出：SRT / VTT / JSON / 纯文本。
///
/// 对应 Python 端 `voice_small_asr/subtitles.py`，并额外支持双语字幕
/// （原文一行、译文一行），供「识别视频语言并翻译成中文」使用。
library;

import 'dart:convert';

import 'package:vsasr_app/src/asr/segment.dart';

/// 支持的导出格式。
const List<String> kSubtitleFormats = <String>['srt', 'vtt', 'json', 'txt'];

/// 单条字幕的默认字符上限（CJK 按字计，约两行的量）。
const int kDefaultMaxChars = 28;

/// 单条字幕的默认时长上限（秒）。
const double kDefaultMaxDuration = 6.0;

/// 一条字幕。
class Cue {
  const Cue({
    required this.text,
    required this.start,
    required this.end,
    this.translation,
  });

  final String text;
  final double start;
  final double end;
  final String? translation;
}

/// 格式化为 `HH:MM:SS,mmm`（SRT）或 `HH:MM:SS.mmm`（VTT）。
String formatTimestamp(double seconds, {String sep = ','}) {
  final int totalMs = (seconds <= 0 ? 0.0 : seconds * 1000).round();
  final int hours = totalMs ~/ 3600000;
  final int minutes = (totalMs % 3600000) ~/ 60000;
  final int secs = (totalMs % 60000) ~/ 1000;
  final int ms = totalMs % 1000;
  final String hh = hours.toString().padLeft(2, '0');
  final String mm = minutes.toString().padLeft(2, '0');
  final String ss = secs.toString().padLeft(2, '0');
  final String mmm = ms.toString().padLeft(3, '0');
  return '$hh:$mm:$ss$sep$mmm';
}

/// 按 token 时间戳把长段切成多条字幕。
Iterable<Cue> _splitByWords(
  Segment seg,
  int maxChars,
  double maxDuration,
) {
  final List<Cue> cues = <Cue>[];
  List<Word> chunk = <Word>[];

  void flush() {
    if (chunk.isEmpty) return;
    final String text = chunk.map((Word w) => w.text).join().trim();
    if (text.isNotEmpty) {
      cues.add(Cue(text: text, start: chunk.first.start, end: chunk.last.end));
    }
    chunk = <Word>[];
  }

  for (final Word word in seg.words) {
    final int pending = chunk.fold<int>(0, (int n, Word w) => n + w.text.length);
    final bool tooLong = pending + word.text.length > maxChars;
    final bool tooSlow = chunk.isNotEmpty && word.end - chunk.first.start > maxDuration;
    if (chunk.isNotEmpty && (tooLong || tooSlow)) flush();
    chunk.add(word);
  }
  flush();
  return cues;
}

/// 没有 token 时间戳时，按字符数均分时间。
///
/// 除字符上限外还要收紧到 [maxDuration]：VAD 会在
/// `maxSpeechDuration`（默认 20 秒）处硬切，这种长段若只按字符切，
/// 会留下挂在屏幕上二十秒的字幕。
Iterable<Cue> _splitEvenly(Segment seg, int maxChars, double maxDuration) {
  final String text = seg.text.trim();
  if (text.isEmpty) return const <Cue>[];
  final double span = seg.duration;
  final int total = text.length;
  int step = maxChars;
  if (maxDuration > 0 && span > maxDuration) {
    final double secondsPerChar = span / total;
    final int fits = (maxDuration / secondsPerChar).floor();
    step = step < fits ? step : fits;
    if (step < 1) step = 1;
  }
  final List<Cue> cues = <Cue>[];
  for (int offset = 0; offset < total; offset += step) {
    final int end = (offset + step) < total ? offset + step : total;
    cues.add(
      Cue(
        text: text.substring(offset, end),
        start: seg.start + span * offset / total,
        end: seg.start + span * end / total,
      ),
    );
  }
  return cues;
}

/// 把识别段展开为字幕条目，过长的段会被切分。
///
/// 带译文的段不做切分：译文与原文的字符边界无法对齐，切了会错位。
List<Cue> buildCues(
  Iterable<Segment> segments, {
  int maxChars = kDefaultMaxChars,
  double maxDuration = kDefaultMaxDuration,
}) {
  final List<Cue> cues = <Cue>[];
  for (final Segment seg in segments) {
    final String text = seg.text.trim();
    if (text.isEmpty) continue;
    final bool hasTranslation = (seg.translation ?? '').trim().isNotEmpty;
    final bool shortEnough = text.length <= maxChars && seg.duration <= maxDuration;
    if (shortEnough || hasTranslation) {
      cues.add(
        Cue(
          text: text,
          start: seg.start,
          end: seg.end,
          translation: hasTranslation ? seg.translation!.trim() : null,
        ),
      );
    } else if (seg.words.isNotEmpty) {
      cues.addAll(_splitByWords(seg, maxChars, maxDuration));
    } else {
      cues.addAll(_splitEvenly(seg, maxChars, maxDuration));
    }
  }
  return cues;
}

/// 零长度字幕在播放器里可能被跳过，至少给 1 ms。
double _safeEnd(Cue cue) => cue.end > cue.start ? cue.end : cue.start + 0.001;

List<String> _cueLines(Cue cue, bool bilingual, bool translationFirst) {
  final String? translated = cue.translation;
  if (!bilingual || translated == null || translated.isEmpty) {
    return <String>[cue.text];
  }
  return translationFirst ? <String>[translated, cue.text] : <String>[cue.text, translated];
}

/// 生成 SRT 字幕内容。[bilingual] 为真且段带译文时输出双行。
String toSrt(
  Iterable<Segment> segments, {
  int maxChars = kDefaultMaxChars,
  double maxDuration = kDefaultMaxDuration,
  bool bilingual = true,
  bool translationFirst = false,
}) {
  final StringBuffer buf = StringBuffer();
  int number = 1;
  for (final Cue cue in buildCues(segments, maxChars: maxChars, maxDuration: maxDuration)) {
    buf.writeln(number++);
    buf.writeln('${formatTimestamp(cue.start)} --> ${formatTimestamp(_safeEnd(cue))}');
    for (final String line in _cueLines(cue, bilingual, translationFirst)) {
      buf.writeln(line);
    }
    buf.writeln();
  }
  return buf.toString();
}

/// 生成 WebVTT 字幕内容。
String toVtt(
  Iterable<Segment> segments, {
  int maxChars = kDefaultMaxChars,
  double maxDuration = kDefaultMaxDuration,
  bool bilingual = true,
  bool translationFirst = false,
}) {
  final StringBuffer buf = StringBuffer()
    ..writeln('WEBVTT')
    ..writeln();
  for (final Cue cue in buildCues(segments, maxChars: maxChars, maxDuration: maxDuration)) {
    buf.writeln(
      '${formatTimestamp(cue.start, sep: '.')} --> ${formatTimestamp(_safeEnd(cue), sep: '.')}',
    );
    for (final String line in _cueLines(cue, bilingual, translationFirst)) {
      buf.writeln(line);
    }
    buf.writeln();
  }
  return buf.toString();
}

/// 生成纯文本（每段一行；带译文时译文紧随其后）。
String toTxt(Iterable<Segment> segments, {bool bilingual = true}) {
  final StringBuffer buf = StringBuffer();
  for (final Segment seg in segments) {
    final String text = seg.text.trim();
    if (text.isEmpty) continue;
    buf.writeln(text);
    final String translated = (seg.translation ?? '').trim();
    if (bilingual && translated.isNotEmpty) buf.writeln(translated);
  }
  return buf.toString();
}

/// 按格式渲染识别结果。
String renderSubtitles(
  TranscriptionResult result,
  String format, {
  int maxChars = kDefaultMaxChars,
  double maxDuration = kDefaultMaxDuration,
  bool bilingual = true,
  bool translationFirst = false,
}) {
  switch (format.toLowerCase()) {
    case 'srt':
      return toSrt(
        result.segments,
        maxChars: maxChars,
        maxDuration: maxDuration,
        bilingual: bilingual,
        translationFirst: translationFirst,
      );
    case 'vtt':
      return toVtt(
        result.segments,
        maxChars: maxChars,
        maxDuration: maxDuration,
        bilingual: bilingual,
        translationFirst: translationFirst,
      );
    case 'json':
      return const JsonEncoder.withIndent('  ').convert(result.toJson());
    case 'txt':
      return toTxt(result.segments, bilingual: bilingual);
    default:
      throw ArgumentError.value(format, 'format', '不支持的格式，可选 $kSubtitleFormats');
  }
}
