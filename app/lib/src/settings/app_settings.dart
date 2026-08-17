/// 持久化的应用设置与配置读取。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/settings/translation_secrets.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';

const String _languageKey = 'settings.asr.language';
const String _useItnKey = 'settings.asr.use_itn';
const String _numThreadsKey = 'settings.asr.num_threads';
const String _partialIntervalKey = 'settings.asr.partial_interval';
const String _vadThresholdKey = 'settings.vad.threshold';
const String _minSilenceDurationKey = 'settings.vad.min_silence_duration';
const String _minSpeechDurationKey = 'settings.vad.min_speech_duration';
const String _maxSpeechDurationKey = 'settings.vad.max_speech_duration';
const String _offlineModeKey = 'settings.model.offline_mode';
const String _translationEndpointKey = 'settings.translation.endpoint';
const String _translationModelKey = 'settings.translation.model';
const String _translationTargetLanguageKey =
    'settings.translation.target_language';
const String _recentProjectsKey = 'settings.projects.recent';

/// 最近项目最多保留的路径数，最新打开的项目排在最前面。
const int kMaxRecentProjects = 8;

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
  AppSettingsRepository({
    PreferenceStore? preferences,
    TranslationSecrets? secrets,
  }) : _preferences = preferences ?? SharedPreferencesStore(),
       translationSecrets = secrets ?? TranslationSecrets();

  final PreferenceStore _preferences;
  final TranslationSecrets translationSecrets;

  /// 读取持久化配置。损坏或越界的值回退到当前默认配置，不阻塞应用启动。
  Future<AsrConfig> loadConfig({AsrConfig? fallback}) async {
    final AsrConfig base = fallback ?? AsrConfig();
    final String? storedLanguage = await _preferences.readString(_languageKey);
    final bool? storedUseItn = await _preferences.readBool(_useItnKey);
    final int? storedThreads = await _preferences.readInt(_numThreadsKey);
    final double? storedPartial = await _preferences.readDouble(
      _partialIntervalKey,
    );
    final double? storedThreshold = await _preferences.readDouble(
      _vadThresholdKey,
    );
    final double? storedSilence = await _preferences.readDouble(
      _minSilenceDurationKey,
    );
    final double? storedSpeech = await _preferences.readDouble(
      _minSpeechDurationKey,
    );
    final double? storedMaxSpeech = await _preferences.readDouble(
      _maxSpeechDurationKey,
    );

    final String language =
        storedLanguage != null && kLanguages.contains(storedLanguage)
        ? storedLanguage
        : base.language;
    final int defaultThreads = base.numThreads.clamp(1, 16).toInt();
    final double defaultPartial = base.partialInterval
        .clamp(0.0, 3.0)
        .toDouble();
    final int numThreads = _validInt(storedThreads, min: 1, max: 16)
        ? storedThreads!
        : defaultThreads;
    final double partialInterval =
        _validDouble(storedPartial, min: 0.0, max: 3.0)
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
    await _preferences.writeDouble(
      _minSilenceDurationKey,
      config.vad.minSilenceDuration,
    );
    await _preferences.writeDouble(
      _minSpeechDurationKey,
      config.vad.minSpeechDuration,
    );
    await _preferences.writeDouble(
      _maxSpeechDurationKey,
      config.vad.maxSpeechDuration,
    );
  }

  /// 读取离线模式。离线模式只影响自动准备模型，不影响设置页的显式下载按钮。
  Future<bool> loadOfflineMode() async =>
      await _preferences.readBool(_offlineModeKey) ?? false;

  Future<void> saveOfflineMode(bool enabled) =>
      _preferences.writeBool(_offlineModeKey, enabled);

  /// 读取最近打开或保存的项目路径。偏好损坏时返回空列表，不阻塞启动。
  Future<List<String>> loadRecentProjects() async {
    final String? raw = await _preferences.readString(_recentProjectsKey);
    if (raw == null || raw.trim().isEmpty) return <String>[];
    try {
      return _sanitizeRecentProjects(jsonDecode(raw));
    } on Object {
      return <String>[];
    }
  }

  /// 记住项目路径并移到列表首位；返回写入后的完整列表。
  Future<List<String>> rememberRecentProject(String path) async {
    final String normalized = path.trim();
    if (normalized.isEmpty) return loadRecentProjects();
    final List<String> current = await loadRecentProjects();
    final List<String> updated = <String>[
      normalized,
      ...current.where((String value) => value != normalized),
    ].take(kMaxRecentProjects).toList(growable: false);
    await _preferences.writeString(_recentProjectsKey, jsonEncode(updated));
    return updated;
  }

  /// 从最近项目中移除路径；返回写入后的完整列表。
  Future<List<String>> forgetRecentProject(String path) async {
    final String normalized = path.trim();
    final List<String> current = await loadRecentProjects();
    final List<String> updated = current
        .where((String value) => value != normalized)
        .toList(growable: false);
    if (updated.length != current.length) {
      await _preferences.writeString(_recentProjectsKey, jsonEncode(updated));
    }
    return updated;
  }

  /// 读取第三方翻译 API 的普通配置；API Key 仍由 [translationSecrets] 单独读取。
  Future<TranslationApiSettings> loadTranslationApiSettings({
    TranslationApiSettings? fallback,
  }) async {
    final TranslationApiSettings base =
        fallback ?? const TranslationApiSettings();
    final String? endpoint = await _preferences.readString(
      _translationEndpointKey,
    );
    final String? model = await _preferences.readString(_translationModelKey);
    final String? targetLanguage = await _preferences.readString(
      _translationTargetLanguageKey,
    );
    return TranslationApiSettings(
      endpoint: endpoint?.trim().isNotEmpty == true
          ? endpoint!.trim()
          : base.endpoint,
      model: model?.trim().isNotEmpty == true ? model!.trim() : base.model,
      targetLanguage: targetLanguage?.trim().isNotEmpty == true
          ? targetLanguage!.trim()
          : base.targetLanguage,
    );
  }

  /// 持久化第三方翻译 API 的 endpoint 和模型名，不保存 API Key。
  Future<void> saveTranslationApiSettings(
    TranslationApiSettings settings,
  ) async {
    final String endpoint = settings.endpoint.trim();
    final String model = settings.model.trim();
    final String targetLanguage = settings.targetLanguage.trim();
    if (endpoint.isEmpty) {
      throw ArgumentError.value(settings.endpoint, 'endpoint', 'API 地址不能为空');
    }
    if (model.isEmpty) {
      throw ArgumentError.value(settings.model, 'model', '模型名不能为空');
    }
    if (targetLanguage.isEmpty) {
      throw ArgumentError.value(
        settings.targetLanguage,
        'targetLanguage',
        '目标语言不能为空',
      );
    }
    await _preferences.writeString(_translationEndpointKey, endpoint);
    await _preferences.writeString(_translationModelKey, model);
    await _preferences.writeString(
      _translationTargetLanguageKey,
      targetLanguage,
    );
  }
}

bool _validInt(int? value, {required int min, required int max}) =>
    value != null && value >= min && value <= max;

bool _validDouble(double? value, {required double min, required double max}) =>
    value != null && value.isFinite && value >= min && value <= max;

List<String> _sanitizeRecentProjects(Object? value) {
  if (value is! List) return <String>[];
  final Set<String> seen = <String>{};
  final List<String> paths = <String>[];
  for (final Object? item in value) {
    if (item is! String) continue;
    final String path = item.trim();
    if (path.isEmpty || !seen.add(path)) continue;
    paths.add(path);
    if (paths.length == kMaxRecentProjects) break;
  }
  return paths;
}
