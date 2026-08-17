/// 字幕与文本导出：SRT / VTT / JSON / 纯文本。
///
/// 对应 Python 端 `voice_small_asr/subtitles.py`，并额外支持双语字幕
/// （原文一行、译文一行），供「识别视频语言并翻译成中文」使用。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:vsasr_app/src/asr/segment.dart';

/// 支持的导出格式。
const List<String> kSubtitleFormats = <String>['srt', 'vtt', 'json', 'txt'];

/// 可导入的外部字幕格式；TXT 没有时间轴，不能直接用于视频联动。
const List<String> kSubtitleImportFormats = <String>['srt', 'vtt', 'json'];

const String _projectSchema = 'voicesmallasr.project';

/// 文件选择器返回的字幕文件。Android SAF 可能只有字节，没有本地路径。
class SubtitleFileData {
  const SubtitleFileData({required this.name, this.path, this.bytes});

  final String name;
  final String? path;
  final Uint8List? bytes;
}

/// 选择字幕文件，取消时返回 null。
typedef PickSubtitleFile = Future<SubtitleFileData?> Function();

class _SubtitleTiming {
  const _SubtitleTiming(this.start, this.end);

  final double start;
  final double end;
}

final RegExp _subtitleTimingStart = RegExp(
  r'^\s*(?:\d{1,2}:)?\d{2}:\d{2}(?:[,.]\d{1,3})?\s*-->',
);

/// 解析 SRT、VTT 或本项目导出的字幕 JSON。
///
/// 导入结果会统一成 [TranscriptionResult]，并复用项目时间轴校验；导入的
/// JSON 应是 `renderSubtitles(result, 'json')` 生成的结果 JSON，项目 JSON
/// 请使用“打开项目”入口以保留媒体路径和识别配置。
TranscriptionResult parseSubtitleText(
  String content, {
  required String format,
}) {
  final String normalizedFormat = format.trim().toLowerCase().replaceFirst(
    '.',
    '',
  );
  final String normalized = content
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  if (normalized.trim().isEmpty) {
    throw const FormatException('字幕文件为空');
  }
  switch (normalizedFormat) {
    case 'srt':
      return _parseTimedSubtitle(normalized, format: 'SRT');
    case 'vtt':
      return _parseTimedSubtitle(normalized, format: 'VTT');
    case 'json':
      return _parseSubtitleJson(normalized);
    default:
      throw FormatException('不支持导入的字幕格式：$format');
  }
}

TranscriptionResult _parseTimedSubtitle(
  String content, {
  required String format,
}) {
  final List<String> lines = content.split('\n');
  final List<Segment> segments = <Segment>[];
  int index = 0;
  int lineNumber = 0;
  while (lineNumber < lines.length) {
    final String line = lines[lineNumber].trim();
    if (!_subtitleTimingStart.hasMatch(line)) {
      lineNumber++;
      continue;
    }
    final _SubtitleTiming timing;
    try {
      timing = _parseSubtitleTiming(line);
    } on FormatException catch (error) {
      throw FormatException('$format 第 ${lineNumber + 1} 行：${error.message}');
    }
    lineNumber++;
    final List<String> textLines = <String>[];
    while (lineNumber < lines.length &&
        lines[lineNumber].trim().isNotEmpty &&
        !_subtitleTimingStart.hasMatch(lines[lineNumber])) {
      final String text = lines[lineNumber].trim();
      textLines.add(_stripSubtitleMarkup(text));
      lineNumber++;
    }
    final String text = textLines
        .where((String value) => value.isNotEmpty)
        .join('\n')
        .trim();
    if (text.isNotEmpty) {
      segments.add(
        Segment(
          text: text,
          start: timing.start,
          end: timing.end,
          index: index++,
        ),
      );
    }
  }
  if (segments.isEmpty) {
    throw FormatException('$format 中没有找到有效字幕条目');
  }
  return _buildImportedResult(segments);
}

_SubtitleTiming _parseSubtitleTiming(String line) {
  final int arrow = line.indexOf('-->');
  if (arrow < 0) throw const FormatException('缺少 --> 时间分隔符');
  final String startText = line.substring(0, arrow).trim();
  final String endText = line
      .substring(arrow + 3)
      .trim()
      .split(RegExp(r'\s+'))
      .first;
  final double start = _parseSubtitleTimestamp(startText);
  final double end = _parseSubtitleTimestamp(endText);
  if (end <= start) throw const FormatException('结束时间必须晚于开始时间');
  return _SubtitleTiming(start, end);
}

double _parseSubtitleTimestamp(String value) {
  final List<String> clock = value.trim().split(':');
  if (clock.length != 2 && clock.length != 3) {
    throw FormatException('时间格式无效：$value');
  }
  final String secondsText = clock.last.replaceFirst(',', '.');
  final List<String> secondParts = secondsText.split('.');
  if (secondParts.length > 2) {
    throw FormatException('时间格式无效：$value');
  }
  final int? wholeSeconds = int.tryParse(secondParts.first);
  final String fraction = secondParts.length == 2 ? secondParts[1] : '';
  final int? fractionValue = fraction.isEmpty
      ? 0
      : int.tryParse(fraction.padRight(3, '0').substring(0, 3));
  if (wholeSeconds == null || fractionValue == null || wholeSeconds >= 60) {
    throw FormatException('时间格式无效：$value');
  }
  final int? minutes = int.tryParse(clock[clock.length == 3 ? 1 : 0]);
  final int? hours = clock.length == 3 ? int.tryParse(clock.first) : 0;
  if (minutes == null || hours == null || minutes >= 60 || hours < 0) {
    throw FormatException('时间格式无效：$value');
  }
  return hours * 3600 + minutes * 60 + wholeSeconds + fractionValue / 1000;
}

String _stripSubtitleMarkup(String value) =>
    value.replaceAll(RegExp(r'<[^>]+>'), '').trim();

TranscriptionResult _parseSubtitleJson(String content) {
  final Object? decoded;
  try {
    decoded = jsonDecode(content);
  } on Object catch (error) {
    throw FormatException('字幕 JSON 无法解析：$error');
  }
  if (decoded is Map<String, dynamic> && decoded['schema'] == _projectSchema) {
    throw const FormatException('这是项目 JSON，请使用“打开项目”入口');
  }
  final TranscriptionResult result;
  try {
    result = TranscriptionResult.fromJson(decoded);
  } on Object catch (error) {
    throw FormatException('字幕 JSON 结构无效：$error');
  }
  final double maximumEnd = result.segments.fold<double>(
    0,
    (double maximum, Segment segment) =>
        segment.end > maximum ? segment.end : maximum,
  );
  final TranscriptionResult normalized = result.duration > 0
      ? result
      : result.copyWith(duration: maximumEnd);
  ensureValidSubtitleTimeline(
    normalized.segments,
    duration: normalized.duration,
  );
  return normalized;
}

TranscriptionResult _buildImportedResult(List<Segment> segments) {
  final double duration = segments.fold<double>(
    0,
    (double maximum, Segment segment) =>
        segment.end > maximum ? segment.end : maximum,
  );
  final TranscriptionResult result = TranscriptionResult(
    language: 'auto',
    duration: duration,
    segments: List<Segment>.unmodifiable(segments),
  );
  ensureValidSubtitleTimeline(result.segments, duration: result.duration);
  return result;
}

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

/// 检查识别段是否能安全地作为字幕时间轴导出。
///
/// 相邻字幕允许无缝衔接，但不允许倒序或重叠；[duration] 大于 0 时，字幕也不能
/// 超出音频总时长。编辑器与最终导出共用这一条校验，避免只在界面层保证约束。
List<String> validateSubtitleTimeline(
  Iterable<Segment> segments, {
  double? duration,
}) {
  final List<String> errors = <String>[];
  double? previousEnd;
  int index = 0;
  for (final Segment segment in segments) {
    if (!segment.start.isFinite || !segment.end.isFinite) {
      errors.add('第 ${index + 1} 条字幕的时间不是有效数字');
    } else {
      if (segment.start < 0) errors.add('第 ${index + 1} 条字幕不能从负数秒开始');
      if (segment.end <= segment.start) errors.add('第 ${index + 1} 条字幕的结束时间必须晚于开始时间');
      if (previousEnd != null && segment.start < previousEnd - 0.000001) {
        errors.add('第 ${index + 1} 条字幕与上一条重叠或倒序');
      }
      if (duration != null && duration > 0 && segment.end > duration + 0.000001) {
        errors.add('第 ${index + 1} 条字幕超出音频时长');
      }
      previousEnd = segment.end;
    }
    index++;
  }
  return errors;
}

/// 时间轴不合法时阻止导出。
void ensureValidSubtitleTimeline(
  Iterable<Segment> segments, {
  double? duration,
}) {
  final List<String> errors = validateSubtitleTimeline(segments, duration: duration);
  if (errors.isNotEmpty) throw ArgumentError('字幕时间轴无效：${errors.first}');
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
  ensureValidSubtitleTimeline(result.segments, duration: result.duration);
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
