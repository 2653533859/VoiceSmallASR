/// 字幕校对编辑状态：时间轴约束、合并/拆分与撤销/重做。
library;

import 'package:flutter/foundation.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

/// 用户输入不满足字幕编辑约束时抛出的异常。
class SubtitleEditException implements Exception {
  const SubtitleEditException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 管理一份可校对的字幕结果。
///
/// 每次成功编辑保存一个不可变快照，因此撤销/重做不会共享可变列表，也不会
/// 影响识别控制器当前正在显示的结果。
class SubtitleEditorController extends ChangeNotifier {
  SubtitleEditorController({required TranscriptionResult initial})
      : _result = _withIndexes(initial) {
    _ensureValid(_result);
  }

  TranscriptionResult _result;
  final List<TranscriptionResult> _undo = <TranscriptionResult>[];
  final List<TranscriptionResult> _redo = <TranscriptionResult>[];

  TranscriptionResult get result => _result;

  bool get canUndo => _undo.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  /// 修改一条字幕的文本和/或时间。
  ///
  /// 文本发生变化时清除旧译文，因为旧译文已经不再对应新的原文；token 时间戳
  /// 也随之失效，因此一并清空。
  void updateSegment(
    int index, {
    String? text,
    double? start,
    double? end,
  }) {
    final Segment current = _segmentAt(index);
    final String nextText = text?.trim() ?? current.text;
    if (nextText.isEmpty) throw const SubtitleEditException('字幕文本不能为空');
    final bool textChanged = nextText != current.text;
    final bool timingChanged = start != null || end != null;
    final double nextStart = start ?? current.start;
    final double nextEnd = end ?? current.end;
    if (nextText == current.text && nextStart == current.start && nextEnd == current.end) return;
    final Segment next = Segment(
      text: nextText,
      start: nextStart,
      end: nextEnd,
      words: textChanged || timingChanged ? const <Word>[] : current.words,
      language: current.language,
      isFinal: current.isFinal,
      index: current.index,
      translation: textChanged ? null : current.translation,
    );
    final List<Segment> segments = List<Segment>.of(_result.segments);
    segments[index] = next;
    _commit(segments);
  }

  /// 合并第 [index] 条与下一条字幕。
  void mergeSegments(int index) {
    if (index < 0 || index + 1 >= _result.segments.length) {
      throw const SubtitleEditException('没有可合并的下一条字幕');
    }
    final Segment first = _result.segments[index];
    final Segment second = _result.segments[index + 1];
    final Segment merged = Segment(
      text: '${first.text.trim()} ${second.text.trim()}'.trim(),
      start: first.start,
      end: second.end,
      language: first.language,
      isFinal: true,
      index: first.index,
    );
    final List<Segment> segments = List<Segment>.of(_result.segments)
      ..replaceRange(index, index + 2, <Segment>[merged]);
    _commit(segments);
  }

  /// 按字符位置与时间点拆分第 [index] 条字幕。
  void splitSegment(int index, {required int characterOffset, required double splitTime}) {
    final Segment current = _segmentAt(index);
    final String text = current.text.trim();
    if (characterOffset <= 0 || characterOffset >= text.length) {
      throw const SubtitleEditException('分割位置必须在字幕文本中间');
    }
    if (!splitTime.isFinite || splitTime <= current.start || splitTime >= current.end) {
      throw const SubtitleEditException('分割时间必须位于当前字幕的起止时间之间');
    }
    final List<Segment> segments = List<Segment>.of(_result.segments)
      ..replaceRange(
        index,
        index + 1,
        <Segment>[
          Segment(
            text: text.substring(0, characterOffset).trim(),
            start: current.start,
            end: splitTime,
            language: current.language,
            isFinal: true,
            index: current.index,
          ),
          Segment(
            text: text.substring(characterOffset).trim(),
            start: splitTime,
            end: current.end,
            language: current.language,
            isFinal: true,
            index: current.index + 1,
          ),
        ],
      );
    _commit(segments);
  }

  /// 将整份字幕和 token 时间戳一起平移 [seconds] 秒。
  void shiftTimeOffset(double seconds) {
    if (!seconds.isFinite) {
      throw const SubtitleEditException('时间偏移必须是有限数字');
    }
    if (seconds == 0) return;
    final List<Segment> segments = _result.segments
        .map((Segment segment) {
          final List<Word> words = segment.words
              .map(
                (Word word) => Word(
                  text: word.text,
                  start: word.start + seconds,
                  end: word.end + seconds,
                ),
              )
              .toList(growable: false);
          return segment.copyWith(
            start: segment.start + seconds,
            end: segment.end + seconds,
            words: words,
          );
        })
        .toList(growable: false);
    _commit(segments);
  }

  /// 在所有字幕文本中替换 [query]，返回实际替换次数。
  ///
  /// 文本发生变化的字幕会清除旧译文和 token 时间戳，未匹配到内容时不新增
  /// 撤销记录。
  int replaceText({
    required String query,
    required String replacement,
    bool caseSensitive = true,
  }) {
    if (query.isEmpty) {
      throw const SubtitleEditException('搜索内容不能为空');
    }
    final RegExp pattern = RegExp(
      RegExp.escape(query),
      caseSensitive: caseSensitive,
    );
    int replacements = 0;
    final List<Segment> segments = _result.segments
        .map((Segment segment) {
          final int count = pattern.allMatches(segment.text).length;
          if (count == 0) return segment;
          final String nextText = segment.text.replaceAll(pattern, replacement);
          if (nextText == segment.text) return segment;
          replacements += count;
          return Segment(
            text: nextText,
            start: segment.start,
            end: segment.end,
            language: segment.language,
            isFinal: segment.isFinal,
            index: segment.index,
          );
        })
        .toList(growable: false);
    if (replacements == 0) return 0;
    _commit(segments);
    return replacements;
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_result);
    _result = _undo.removeLast();
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_result);
    _result = _redo.removeLast();
    notifyListeners();
  }

  Segment _segmentAt(int index) {
    if (index < 0 || index >= _result.segments.length) {
      throw const SubtitleEditException('字幕序号无效');
    }
    return _result.segments[index];
  }

  void _commit(List<Segment> segments) {
    final TranscriptionResult next = _result.copyWith(segments: _withIndexesFrom(segments));
    _ensureValid(next);
    _undo.add(_result);
    _result = next;
    _redo.clear();
    notifyListeners();
  }

  static TranscriptionResult _withIndexes(TranscriptionResult result) =>
      result.copyWith(segments: _withIndexesFrom(result.segments));

  static List<Segment> _withIndexesFrom(Iterable<Segment> source) {
    final List<Segment> items = List<Segment>.of(source);
    return <Segment>[
      for (int i = 0; i < items.length; i++) items[i].copyWith(index: i, isFinal: true),
    ];
  }

  void _ensureValid(TranscriptionResult result) {
    final List<String> errors = validateSubtitleTimeline(
      result.segments,
      duration: result.duration,
    );
    if (errors.isNotEmpty) throw SubtitleEditException(errors.first);
    for (final Segment segment in result.segments) {
      if (segment.text.trim().isEmpty) throw const SubtitleEditException('字幕文本不能为空');
    }
  }
}
