/// 识别配置与常量。对应 Python 端 `voice_small_asr/config.py`。
library;

/// SenseVoice 支持的语言代码，`auto` 为自动检测。
const List<String> kLanguages = <String>['auto', 'zh', 'en', 'ja', 'ko', 'yue'];

/// 语言代码到中文名的映射，用于界面展示。
const Map<String, String> kLanguageLabels = <String, String>{
  'auto': '自动检测',
  'zh': '中文',
  'en': '英文',
  'yue': '粤语',
  'ja': '日文',
  'ko': '韩文',
};

/// 模型要求的采样率，所有音频都会被重采样到该值。
const int kSampleRate = 16000;

/// 端点检测（silero-vad）参数。
///
/// 这些值直接决定流式识别的延迟与断句质量：
/// [minSilenceDuration] 越小上屏越快，但容易把一句话切碎。
class VadConfig {
  const VadConfig({
    this.threshold = 0.5,
    this.minSilenceDuration = 0.35,
    this.minSpeechDuration = 0.25,
    this.maxSpeechDuration = 20.0,
    this.windowSize = 512,
  });

  final double threshold;

  /// 判定句子结束所需的静音时长（秒）。
  final double minSilenceDuration;

  /// 短于此长度的语音段被丢弃（秒），用于过滤咳嗽、点击噪声。
  final double minSpeechDuration;

  /// 单个语音段的硬上限（秒），超过则强制切分。
  final double maxSpeechDuration;

  /// silero-vad 要求 16 kHz 下窗口为 512 采样点。
  final int windowSize;

  factory VadConfig.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('config.vad 必须是 JSON 对象');
    }
    final double threshold = _configDouble(
      value['threshold'],
      'config.vad.threshold',
      fallback: 0.5,
    );
    final double minSilenceDuration = _configDouble(
      value['min_silence_duration'],
      'config.vad.min_silence_duration',
      fallback: 0.35,
    );
    final double minSpeechDuration = _configDouble(
      value['min_speech_duration'],
      'config.vad.min_speech_duration',
      fallback: 0.25,
    );
    final double maxSpeechDuration = _configDouble(
      value['max_speech_duration'],
      'config.vad.max_speech_duration',
      fallback: 20.0,
    );
    final int windowSize = _configInt(
      value['window_size'],
      'config.vad.window_size',
      fallback: 512,
    );
    if (threshold < 0 ||
        threshold > 1 ||
        minSilenceDuration < 0 ||
        minSpeechDuration < 0 ||
        maxSpeechDuration <= 0 ||
        windowSize <= 0) {
      throw const FormatException('config.vad 包含越界值');
    }
    return VadConfig(
      threshold: threshold,
      minSilenceDuration: minSilenceDuration,
      minSpeechDuration: minSpeechDuration,
      maxSpeechDuration: maxSpeechDuration,
      windowSize: windowSize,
    );
  }

  VadConfig copyWith({
    double? threshold,
    double? minSilenceDuration,
    double? minSpeechDuration,
    double? maxSpeechDuration,
    int? windowSize,
  }) {
    return VadConfig(
      threshold: threshold ?? this.threshold,
      minSilenceDuration: minSilenceDuration ?? this.minSilenceDuration,
      minSpeechDuration: minSpeechDuration ?? this.minSpeechDuration,
      maxSpeechDuration: maxSpeechDuration ?? this.maxSpeechDuration,
      windowSize: windowSize ?? this.windowSize,
    );
  }
}

/// 识别器配置。
class AsrConfig {
  AsrConfig({
    this.language = 'auto',
    this.useItn = true,
    this.numThreads = 2,
    this.partialInterval = 0.6,
    this.vad = const VadConfig(),
    this.provider = 'auto',
  }) {
    if (!kLanguages.contains(language)) {
      throw ArgumentError.value(language, 'language', '必须是 $kLanguages 之一');
    }
    if (numThreads < 1) {
      throw ArgumentError.value(numThreads, 'numThreads', '必须 >= 1');
    }
    if (partialInterval < 0) {
      throw ArgumentError.value(partialInterval, 'partialInterval', '不能为负');
    }
  }

  /// `auto`/`zh`/`en`/`ja`/`ko`/`yue`。粤语建议显式传 `yue`。
  final String language;

  /// 逆文本标准化。开启后输出标点与阿拉伯数字，生成字幕时应保持开启。
  final bool useItn;

  /// onnxruntime 线程数。
  final int numThreads;

  /// 流式局部结果的最小间隔（秒）。设为 0 关闭局部结果，只输出定稿句子。
  final double partialInterval;

  /// 推理运行时的后端提供者。
  /// 可选值：`auto` (根据平台自动选择), `cpu`, `nnapi` (Android), `coreml` (macOS).
  final String provider;

  final VadConfig vad;

  factory AsrConfig.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('config 必须是 JSON 对象');
    }
    return AsrConfig(
      language: _configString(
        value['language'],
        'config.language',
        fallback: 'auto',
      ),
      useItn: _configBool(value['use_itn'], 'config.use_itn', fallback: true),
      numThreads: _configInt(
        value['num_threads'],
        'config.num_threads',
        fallback: 2,
      ),
      partialInterval: _configDouble(
        value['partial_interval'],
        'config.partial_interval',
        fallback: 0.6,
      ),
      provider: _configString(
        value['provider'],
        'config.provider',
        fallback: 'auto',
      ),
      vad: VadConfig.fromJson(value['vad'] ?? const <String, Object?>{}),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'language': language,
    'use_itn': useItn,
    'num_threads': numThreads,
    'partial_interval': partialInterval,
    'provider': provider,
    'vad': <String, dynamic>{
      'threshold': vad.threshold,
      'min_silence_duration': vad.minSilenceDuration,
      'min_speech_duration': vad.minSpeechDuration,
      'max_speech_duration': vad.maxSpeechDuration,
      'window_size': vad.windowSize,
    },
  };

  /// 转换为 sherpa-onnx 期望的取值（`auto` 对应空串）。
  String get senseVoiceLanguage => language == 'auto' ? '' : language;

  AsrConfig copyWith({
    String? language,
    bool? useItn,
    int? numThreads,
    double? partialInterval,
    VadConfig? vad,
    String? provider,
  }) {
    return AsrConfig(
      language: language ?? this.language,
      useItn: useItn ?? this.useItn,
      numThreads: numThreads ?? this.numThreads,
      partialInterval: partialInterval ?? this.partialInterval,
      vad: vad ?? this.vad,
      provider: provider ?? this.provider,
    );
  }
}

String _configString(Object? value, String field, {required String fallback}) {
  if (value == null) return fallback;
  if (value is String) return value;
  throw FormatException('$field 必须是字符串');
}

bool _configBool(Object? value, String field, {required bool fallback}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  throw FormatException('$field 必须是布尔值');
}

double _configDouble(Object? value, String field, {required double fallback}) {
  if (value == null) return fallback;
  if (value is num && value.isFinite) return value.toDouble();
  throw FormatException('$field 必须是有限数字');
}

int _configInt(Object? value, String field, {required int fallback}) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.round()) {
    return value.toInt();
  }
  throw FormatException('$field 必须是整数');
}
