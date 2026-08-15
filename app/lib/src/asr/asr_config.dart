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

  final VadConfig vad;

  /// 转换为 sherpa-onnx 期望的取值（`auto` 对应空串）。
  String get senseVoiceLanguage => language == 'auto' ? '' : language;

  AsrConfig copyWith({
    String? language,
    bool? useItn,
    int? numThreads,
    double? partialInterval,
    VadConfig? vad,
  }) {
    return AsrConfig(
      language: language ?? this.language,
      useItn: useItn ?? this.useItn,
      numThreads: numThreads ?? this.numThreads,
      partialInterval: partialInterval ?? this.partialInterval,
      vad: vad ?? this.vad,
    );
  }
}
