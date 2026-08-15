/// 持久化的应用设置与配置读取。
library;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/settings/translation_secrets.dart';

const String _languageKey = 'settings.asr.language';
const String _useItnKey = 'settings.asr.use_itn';
const String _numThreadsKey = 'settings.asr.num_threads';
const String _partialIntervalKey = 'settings.asr.partial_interval';
const String _vadThresholdKey = 'settings.vad.threshold';
const String _minSilenceDurationKey = 'settings.vad.min_silence_duration';
const String _minSpeechDurationKey = 'settings.vad.min_speech_duration';
const String _maxSpeechDurationKey = 'settings.vad.max_speech_duration';
const String _offlineModeKey = 'settings.model.offline_mode';

/// 可替换的普通设置存储，便于在没有平台 channel 的单测里验证持久化逻辑。
abstract interface class PreferenceStore {
  Future<String?> readString(String key);

  Future<bool?> readBool(String key);

  Future<int?> readInt(String key);

  Future<double?> readDouble(String key);

  Future<void> writeString(String key, String value);

  Future<void> writeBool(String key, bool value);

  Future<void> writeInt(String key, int value);

  Future<void> writeDouble(String key, double value);
}

/// 基于 shared_preferences 新异步 API 的跨平台实现。
class SharedPreferencesStore implements PreferenceStore {
  SharedPreferencesStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> readString(String key) => _preferences.getString(key);

  @override
  Future<bool?> readBool(String key) => _preferences.getBool(key);

  @override
  Future<int?> readInt(String key) => _preferences.getInt(key);

  @override
  Future<double?> readDouble(String key) => _preferences.getDouble(key);

  @override
  Future<void> writeString(String key, String value) async {
    await _preferences.setString(key, value);
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    await _preferences.setBool(key, value);
  }

  @override
  Future<void> writeInt(String key, int value) async {
    await _preferences.setInt(key, value);
  }

  @override
  Future<void> writeDouble(String key, double value) async {
    await _preferences.setDouble(key, value);
  }
}

/// 负责把普通设置和安全存储的密钥组合起来。
class AppSettingsRepository {
  AppSettingsRepository({PreferenceStore? preferences, TranslationSecrets? secrets})
    : _preferences = preferences ?? SharedPreferencesStore(),
      translationSecrets = secrets ?? TranslationSecrets();

  final PreferenceStore _preferences;
  final TranslationSecrets translationSecrets;

  /// 读取持久化配置。损坏或越界的值回退到当前默认配置，不阻塞应用启动。
  Future<AsrConfig> loadConfig({AsrConfig? fallback}) async {
    final AsrConfig base = fallback ?? AsrConfig();
    final String? storedLanguage = await _preferences.readString(_languageKey);
    final bool? storedUseItn = await _preferences.readBool(_useItnKey);
    final int? storedThreads = await _preferences.readInt(_numThreadsKey);
    final double? storedPartial = await _preferences.readDouble(_partialIntervalKey);
    final double? storedThreshold = await _preferences.readDouble(_vadThresholdKey);
    final double? storedSilence = await _preferences.readDouble(_minSilenceDurationKey);
    final double? storedSpeech = await _preferences.readDouble(_minSpeechDurationKey);
    final double? storedMaxSpeech = await _preferences.readDouble(_maxSpeechDurationKey);

    final String language = storedLanguage != null && kLanguages.contains(storedLanguage)
        ? storedLanguage
        : base.language;
    final int defaultThreads = base.numThreads.clamp(1, 16).toInt();
    final double defaultPartial = base.partialInterval.clamp(0.0, 3.0).toDouble();
    final int numThreads = _validInt(storedThreads, min: 1, max: 16) ? storedThreads! : defaultThreads;
    final double partialInterval = _validDouble(storedPartial, min: 0.0, max: 3.0)
        ? storedPartial!
        : defaultPartial;
    final VadConfig baseVad = base.vad;
    final VadConfig vad = baseVad.copyWith(
      threshold: _validDouble(storedThreshold, min: 0.1, max: 0.9)
          ? storedThreshold
          : baseVad.threshold.clamp(0.1, 0.9).toDouble(),
      minSilenceDuration: _validDouble(storedSilence, min: 0.1, max: 1.5)
          ? storedSilence
          : baseVad.minSilenceDuration.clamp(0.1, 1.5).toDouble(),
      minSpeechDuration: _validDouble(storedSpeech, min: 0.0, max: 10.0)
          ? storedSpeech
          : baseVad.minSpeechDuration,
      maxSpeechDuration: _validDouble(storedMaxSpeech, min: 0.1, max: 120.0)
          ? storedMaxSpeech
          : baseVad.maxSpeechDuration,
    );
    return base.copyWith(
      language: language,
      useItn: storedUseItn ?? base.useItn,
      numThreads: numThreads,
      partialInterval: partialInterval,
      vad: vad,
    );
  }

  /// 持久化普通设置；API Key 由 [translationSecrets] 单独处理。
  Future<void> saveConfig(AsrConfig config) async {
    await _preferences.writeString(_languageKey, config.language);
    await _preferences.writeBool(_useItnKey, config.useItn);
    await _preferences.writeInt(_numThreadsKey, config.numThreads);
    await _preferences.writeDouble(_partialIntervalKey, config.partialInterval);
    await _preferences.writeDouble(_vadThresholdKey, config.vad.threshold);
    await _preferences.writeDouble(_minSilenceDurationKey, config.vad.minSilenceDuration);
    await _preferences.writeDouble(_minSpeechDurationKey, config.vad.minSpeechDuration);
    await _preferences.writeDouble(_maxSpeechDurationKey, config.vad.maxSpeechDuration);
  }

  /// 读取离线模式。离线模式只影响自动准备模型，不影响设置页的显式下载按钮。
  Future<bool> loadOfflineMode() async => await _preferences.readBool(_offlineModeKey) ?? false;

  Future<void> saveOfflineMode(bool enabled) => _preferences.writeBool(_offlineModeKey, enabled);
}

bool _validInt(int? value, {required int min, required int max}) =>
    value != null && value >= min && value <= max;

bool _validDouble(double? value, {required double min, required double max}) =>
    value != null && value.isFinite && value >= min && value <= max;
