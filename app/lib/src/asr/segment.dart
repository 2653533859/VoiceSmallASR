/// 识别结果的数据结构。对应 Python 端 `voice_small_asr/segments.py`。
///
/// 这些类型是界面层与引擎层之间的契约，不暴露 sherpa_onnx 的任何类型。
library;

/// 一个 token 及其时间范围（秒，相对整段音频起点）。
///
/// 粒度随语言而变：中文、日文、粤语为单字，英文为 subword 或整词。
/// SenseVoice 会把英文词间空格作为独立 token 输出，因此
/// `words.map((w) => w.text).join()` 可以还原文本。
class Word {
  const Word({required this.text, required this.start, required this.end});

  final String text;
  final double start;
  final double end;

  double get duration => end > start ? end - start : 0.0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'text': text,
    'start': _round3(start),
    'end': _round3(end),
  };
}

/// 一个语音段（通常对应一句话）的识别结果。
class Segment {
  const Segment({
    required this.text,
    required this.start,
    required this.end,
    this.words = const <Word>[],
    this.language = '',
    this.isFinal = true,
    this.index = -1,
    this.translation,
  });

  final String text;
  final double start;
  final double end;

  /// token 级时间戳，可能为空。
  final List<Word> words;

  /// 模型判定或调用方指定的语言代码。
  final String language;

  /// `false` 表示流式过程中的局部结果，后续会被同一句的定稿结果替换；
  /// 界面据此决定是覆盖还是追加。
  final bool isFinal;

  /// 定稿段的序号，从 0 开始；局部结果为 -1。
  final int index;

  /// 译文（翻译功能填充），未翻译时为 null。
  final String? translation;

  double get duration => end > start ? end - start : 0.0;

  Segment copyWith({
    String? text,
    double? start,
    double? end,
    List<Word>? words,
    String? language,
    bool? isFinal,
    int? index,
    String? translation,
  }) {
    return Segment(
      text: text ?? this.text,
      start: start ?? this.start,
      end: end ?? this.end,
      words: words ?? this.words,
      language: language ?? this.language,
      isFinal: isFinal ?? this.isFinal,
      index: index ?? this.index,
      translation: translation ?? this.translation,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'index': index,
    'text': text,
    'start': _round3(start),
    'end': _round3(end),
    'language': language,
    'is_final': isFinal,
    if (translation != null) 'translation': translation,
    'words': words.map((Word w) => w.toJson()).toList(),
  };
}

/// 整段音频的识别结果。
class TranscriptionResult {
  const TranscriptionResult({
    this.segments = const <Segment>[],
    this.duration = 0.0,
    this.language = 'auto',
  });

  final List<Segment> segments;

  /// 音频总时长（秒）。
  final double duration;

  /// 调用方请求的语言。
  final String language;

  /// 拼接所有定稿段的文本。
  String get text =>
      segments.where((Segment s) => s.text.isNotEmpty).map((Segment s) => s.text).join(' ').trim();

  bool get isEmpty => segments.isEmpty;

  int get length => segments.length;

  TranscriptionResult copyWith({
    List<Segment>? segments,
    double? duration,
    String? language,
  }) {
    return TranscriptionResult(
      segments: segments ?? this.segments,
      duration: duration ?? this.duration,
      language: language ?? this.language,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'language': language,
    'duration': _round3(duration),
    'text': text,
    'segments': segments.map((Segment s) => s.toJson()).toList(),
  };
}

/// 保留三位小数（毫秒级），避免 JSON 里出现 float 长尾数。
double _round3(double value) => (value * 1000).round() / 1000;
