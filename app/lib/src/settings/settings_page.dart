/// 应用设置页：识别参数与第三方翻译 API 配置。
library;

import 'package:flutter/material.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';

/// 设置页。普通配置保存到偏好存储，API Key 始终交给安全存储。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.repository,
  });

  final TranscribeController controller;
  final AppSettingsRepository repository;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _language;
  String _targetLanguage = kDefaultTranslationTargetLanguage;
  late bool _useItn;
  late bool _offlineMode;
  late int _numThreads;
  late double _partialInterval;
  late double _vadThreshold;
  late double _minSilenceDuration;
  late final TextEditingController _apiEndpoint;
  late final TextEditingController _apiModel;
  late final TextEditingController _apiGlossary;
  late final TextEditingController _apiKey;
  List<TranslationProviderPreset> _translationPresets =
      <TranslationProviderPreset>[];
  String? _selectedPresetId;

  bool _loading = true;
  bool _saving = false;
  bool _testingConnection = false;
  String? _errorText;
  String? _connectionStatus;

  @override
  void initState() {
    super.initState();
    final AsrConfig config = widget.controller.config;
    _language = config.language;
    _useItn = config.useItn;
    _offlineMode = widget.controller.offlineMode;
    _numThreads = config.numThreads.clamp(1, 16).toInt();
    _partialInterval = config.partialInterval.clamp(0.0, 3.0).toDouble();
    _vadThreshold = config.vad.threshold.clamp(0.1, 0.9).toDouble();
    _minSilenceDuration = config.vad.minSilenceDuration
        .clamp(0.1, 1.5)
        .toDouble();
    _apiEndpoint = TextEditingController();
    _apiModel = TextEditingController();
    _apiGlossary = TextEditingController();
    _apiKey = TextEditingController();
    widget.controller.addListener(_onControllerChanged);
    _loadTranslationSettings();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadTranslationSettings() async {
    try {
      final TranslationApiSettings settings = await widget.repository
          .loadTranslationApiSettings();
      final List<TranslationProviderPreset> presets = await widget.repository
          .loadTranslationProviderPresets();
      final String? key = await widget.repository.translationSecrets
          .readApiKey();
      if (!mounted) return;
      _apiEndpoint.text = settings.endpoint;
      _apiModel.text = settings.model;
      _apiGlossary.text = settings.glossary;
      _apiKey.text = key ?? '';
      _targetLanguage = settings.targetLanguage.trim().isEmpty
          ? kDefaultTranslationTargetLanguage
          : settings.targetLanguage.trim();
      setState(() {
        _translationPresets = presets;
        _selectedPresetId = null;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = '读取翻译配置失败：$error';
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _apiEndpoint.dispose();
    _apiModel.dispose();
    _apiGlossary.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_loading || _saving || _testingConnection) return;
    setState(() {
      _saving = true;
      _errorText = null;
      _connectionStatus = null;
    });
    final AsrConfig current = widget.controller.config;
    final AsrConfig next = current.copyWith(
      language: _language,
      useItn: _useItn,
      numThreads: _numThreads,
      partialInterval: _partialInterval,
      vad: current.vad.copyWith(
        threshold: _vadThreshold,
        minSilenceDuration: _minSilenceDuration,
      ),
    );
    try {
      await widget.repository.saveConfig(next);
      await widget.repository.saveOfflineMode(_offlineMode);
      await widget.repository.saveTranslationApiSettings(
        TranslationApiSettings(
          endpoint: _apiEndpoint.text,
          model: _apiModel.text,
          targetLanguage: _targetLanguage,
          glossary: _apiGlossary.text,
        ),
      );
      final String key = _apiKey.text.trim();
      if (key.isEmpty) {
        await widget.repository.translationSecrets.deleteApiKey();
      } else {
        await widget.repository.translationSecrets.saveApiKey(key);
      }
      await widget.controller.applyConfig(next);
      widget.controller.setOfflineMode(_offlineMode);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = '保存设置失败：$error';
      });
    }
  }

  Future<void> _testConnection() async {
    if (_loading || _saving || _testingConnection) return;
    final String apiKey = _apiKey.text.trim();
    if (apiKey.isEmpty) {
      setState(() {
        _connectionStatus = null;
        _errorText = '连接测试失败：请先输入 API Key';
      });
      return;
    }
    final String endpoint = _apiEndpoint.text.trim();
    final String model = _apiModel.text.trim();
    final String glossary = _apiGlossary.text;
    setState(() {
      _testingConnection = true;
      _errorText = null;
      _connectionStatus = '正在测试 ${_safeEndpoint(endpoint)} / 模型 $model…';
    });
    final ApiTranslationProvider provider;
    try {
      provider = ApiTranslationProvider(
        apiKey: apiKey,
        endpoint: endpoint,
        model: model,
        glossary: glossary,
      );
      try {
        await provider.testConnection(targetLanguage: _targetLanguage);
        if (!mounted) return;
        setState(() {
          _connectionStatus =
              '连接成功：${_safeEndpoint(endpoint)} / 模型 $model 已返回响应';
        });
      } finally {
        provider.close();
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _connectionStatus = null;
        _errorText =
            '连接失败（${_safeEndpoint(endpoint)} / 模型 $model）：'
            '${_redactApiKey(error.toString(), apiKey)}';
      });
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  TranslationApiSettings _currentTranslationSettings() =>
      TranslationApiSettings(
        endpoint: _apiEndpoint.text,
        model: _apiModel.text,
        targetLanguage: _targetLanguage,
        glossary: _apiGlossary.text,
      );

  void _onTranslationFieldChanged(String _) {
    if (_selectedPresetId != null) {
      setState(() => _selectedPresetId = null);
    }
  }

  void _applyTranslationPreset(String id) {
    TranslationProviderPreset? selected;
    for (final TranslationProviderPreset preset in _translationPresets) {
      if (preset.id == id) {
        selected = preset;
        break;
      }
    }
    if (selected == null) return;
    final TranslationApiSettings settings = selected.settings;
    _apiEndpoint.text = settings.endpoint;
    _apiModel.text = settings.model;
    _apiGlossary.text = settings.glossary;
    _targetLanguage = settings.targetLanguage.trim().isEmpty
        ? kDefaultTranslationTargetLanguage
        : settings.targetLanguage.trim();
    setState(() => _selectedPresetId = selected!.id);
  }

  Future<void> _saveTranslationPreset() async {
    if (_loading || _saving || _testingConnection) return;
    final TextEditingController nameController = TextEditingController(
      text: _translationPresets
          .where(
            (TranslationProviderPreset preset) =>
                preset.id == _selectedPresetId,
          )
          .map((TranslationProviderPreset preset) => preset.name)
          .firstOrNull,
    );
    final String? name;
    try {
      name = await showDialog<String>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('保存翻译服务预设'),
          content: TextField(
            key: const Key('translationPresetName'),
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '预设名称',
              hintText: '例如：工作账号、备用服务',
            ),
            onSubmitted: (String value) => Navigator.of(context).pop(value),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(nameController.text),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      nameController.dispose();
    }
    if (name == null || !mounted) return;
    try {
      final List<TranslationProviderPreset> presets = await widget.repository
          .saveTranslationProviderPreset(
            name: name,
            settings: _currentTranslationSettings(),
            id: _selectedPresetId,
          );
      if (!mounted) return;
      final String normalizedName = name.trim();
      final TranslationProviderPreset? saved = presets
          .where(
            (TranslationProviderPreset preset) => preset.name == normalizedName,
          )
          .firstOrNull;
      setState(() {
        _translationPresets = presets;
        _selectedPresetId = saved?.id;
        _errorText = null;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已保存翻译服务预设“$normalizedName”')));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _errorText = '保存翻译服务预设失败：$error');
    }
  }

  Future<void> _deleteTranslationPreset() async {
    if (_loading ||
        _saving ||
        _testingConnection ||
        _selectedPresetId == null) {
      return;
    }
    final TranslationProviderPreset? selected = _translationPresets
        .where(
          (TranslationProviderPreset preset) => preset.id == _selectedPresetId,
        )
        .firstOrNull;
    if (selected == null) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除翻译服务预设？'),
        content: Text('将删除预设“${selected.name}”，不会影响当前已填写的配置。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final List<TranslationProviderPreset> presets = await widget.repository
          .deleteTranslationProviderPreset(selected.id);
      if (!mounted) return;
      setState(() {
        _translationPresets = presets;
        _selectedPresetId = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _errorText = '删除翻译服务预设失败：$error');
    }
  }

  List<String> _translationLanguageOptions() {
    final List<String> options = <String>[...kTranslationLanguages];
    final String target = _targetLanguage.trim();
    if (target.isNotEmpty && !options.contains(target)) options.add(target);
    return options;
  }

  Future<void> _deleteModel() async {
    if (_saving || widget.controller.busy || !widget.controller.modelReady) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除本地模型？'),
        content: Text(
          '将删除约 ${_formatBytes(widget.controller.modelBytes)} 的模型文件。下次识别前需要重新下载。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await widget.controller.deleteModel();
  }

  @override
  Widget build(BuildContext context) {
    final bool disabled =
        _loading || _saving || _testingConnection || widget.controller.busy;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: <Widget>[
                Text('识别设置', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('settingsLanguage'),
                  initialValue: _language,
                  decoration: const InputDecoration(labelText: '识别语言'),
                  onChanged: disabled
                      ? null
                      : (String? value) {
                          if (value != null) setState(() => _language = value);
                        },
                  items: <DropdownMenuItem<String>>[
                    for (final String code in kLanguages)
                      DropdownMenuItem<String>(
                        value: code,
                        child: Text(kLanguageLabels[code] ?? code),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  key: const Key('settingsThreads'),
                  initialValue: _numThreads,
                  decoration: const InputDecoration(labelText: '识别线程数'),
                  onChanged: disabled
                      ? null
                      : (int? value) {
                          if (value != null) {
                            setState(() => _numThreads = value);
                          }
                        },
                  items: <DropdownMenuItem<int>>[
                    for (final int value in <int>[
                      1,
                      2,
                      3,
                      4,
                      5,
                      6,
                      7,
                      8,
                      9,
                      10,
                      11,
                      12,
                      13,
                      14,
                      15,
                      16,
                    ])
                      DropdownMenuItem<int>(
                        value: value,
                        child: Text('$value'),
                      ),
                  ],
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用标点与数字规范化'),
                  subtitle: const Text('输出字幕时保留标点和阿拉伯数字'),
                  value: _useItn,
                  onChanged: disabled
                      ? null
                      : (bool value) => setState(() => _useItn = value),
                ),
                Text('翻译', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                if (_translationPresets.isNotEmpty) ...<Widget>[
                  DropdownButtonFormField<String>(
                    key: const Key('translationProviderPreset'),
                    initialValue: _selectedPresetId,
                    decoration: const InputDecoration(
                      labelText: '翻译服务预设',
                      hintText: '选择已保存的 endpoint、模型和术语表组合',
                    ),
                    onChanged: disabled
                        ? null
                        : (String? value) {
                            if (value != null) _applyTranslationPreset(value);
                          },
                    items: <DropdownMenuItem<String>>[
                      for (final TranslationProviderPreset preset
                          in _translationPresets)
                        DropdownMenuItem<String>(
                          value: preset.id,
                          child: Text(preset.name),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('saveTranslationPreset'),
                        onPressed: disabled ? null : _saveTranslationPreset,
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('保存为预设'),
                      ),
                    ),
                    if (_selectedPresetId != null) ...<Widget>[
                      const SizedBox(width: 8),
                      IconButton(
                        key: const Key('deleteTranslationPreset'),
                        tooltip: '删除当前预设',
                        onPressed: disabled ? null : _deleteTranslationPreset,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('translationApiEndpoint'),
                  controller: _apiEndpoint,
                  enabled: !disabled,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  onChanged: _onTranslationFieldChanged,
                  decoration: const InputDecoration(
                    labelText: '翻译 API 地址',
                    hintText: 'OpenAI-compatible /v1/chat/completions 地址',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: const Key('translationTargetLanguage'),
                  initialValue: _targetLanguage,
                  decoration: const InputDecoration(labelText: '翻译目标语言'),
                  onChanged: disabled
                      ? null
                      : (String? value) {
                          if (value != null) {
                            setState(() {
                              _targetLanguage = value;
                              _selectedPresetId = null;
                            });
                          }
                        },
                  items: <DropdownMenuItem<String>>[
                    for (final String code in _translationLanguageOptions())
                      DropdownMenuItem<String>(
                        value: code,
                        child: Text(kTranslationLanguageLabels[code] ?? code),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('translationApiModel'),
                  controller: _apiModel,
                  enabled: !disabled,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: _onTranslationFieldChanged,
                  decoration: const InputDecoration(
                    labelText: '翻译模型',
                    hintText: '例如 gpt-4o-mini 或第三方模型名',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('translationGlossary'),
                  controller: _apiGlossary,
                  enabled: !disabled,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.multiline,
                  minLines: 3,
                  maxLines: 8,
                  onChanged: _onTranslationFieldChanged,
                  decoration: const InputDecoration(
                    labelText: '翻译术语表（可选）',
                    hintText: '每行填写：原词=译词；空行或 # 开头的行会被忽略',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('translationApiKey'),
                  controller: _apiKey,
                  enabled: !disabled,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '第三方翻译 API Key',
                    hintText: '留空可清除已保存的 Key',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                if (widget.repository.translationSecrets.sessionOnly)
                  Text(
                    '当前系统安全存储不可用，API Key 只保存在本次运行内；退出应用后需要重新输入。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  )
                else
                  const Text('API 地址和模型名保存到普通设置；API Key 只保存到系统安全存储。'),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('testTranslationConnection'),
                  onPressed: disabled ? null : _testConnection,
                  icon: _testingConnection
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: Text(_testingConnection ? '测试连接中…' : '测试 API 连接'),
                ),
                if (_connectionStatus != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    _connectionStatus!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
                const Divider(height: 24),
                Text('实时识别', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                _ValueSlider(
                  label: '临时结果间隔',
                  valueText: _partialInterval == 0
                      ? '关闭'
                      : '${_partialInterval.toStringAsFixed(1)} 秒',
                  value: _partialInterval,
                  min: 0,
                  max: 3,
                  divisions: 12,
                  enabled: !disabled,
                  onChanged: (double value) =>
                      setState(() => _partialInterval = value),
                ),
                const SizedBox(height: 8),
                _ValueSlider(
                  label: 'VAD 断句灵敏度',
                  valueText: _vadThreshold.toStringAsFixed(2),
                  value: _vadThreshold,
                  min: 0.1,
                  max: 0.9,
                  divisions: 16,
                  enabled: !disabled,
                  onChanged: (double value) =>
                      setState(() => _vadThreshold = value),
                ),
                _ValueSlider(
                  label: '句末静音时长',
                  valueText: '${_minSilenceDuration.toStringAsFixed(2)} 秒',
                  value: _minSilenceDuration,
                  min: 0.1,
                  max: 1.5,
                  divisions: 28,
                  enabled: !disabled,
                  onChanged: (double value) =>
                      setState(() => _minSilenceDuration = value),
                ),
                const Divider(height: 24),
                Text('模型', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  widget.controller.modelReady
                      ? '模型已就绪，占用 ${_formatBytes(widget.controller.modelBytes)}'
                      : '模型尚未下载',
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('离线模式'),
                  subtitle: const Text('自动准备模型时不联网；设置页仍可手动下载'),
                  value: _offlineMode,
                  onChanged: disabled
                      ? null
                      : (bool value) => setState(() => _offlineMode = value),
                ),
                if (widget.controller.busy) ...<Widget>[
                  LinearProgressIndicator(value: widget.controller.progress),
                  if (widget.controller.statusText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(widget.controller.statusText),
                    ),
                ],
                Row(
                  children: <Widget>[
                    if (!widget.controller.modelReady)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: disabled
                              ? null
                              : widget.controller.downloadModel,
                          icon: const Icon(Icons.download),
                          label: const Text('下载模型'),
                        ),
                      ),
                    if (widget.controller.modelReady)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: disabled ? null : _deleteModel,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除模型'),
                        ),
                      ),
                  ],
                ),
                if (_errorText != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    _errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: disabled ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? '保存中…' : '保存设置'),
                ),
              ],
            ),
    );
  }
}

String _safeEndpoint(String value) {
  try {
    final Uri uri = Uri.parse(value);
    if (uri.host.isEmpty) return '<无效地址>';
    return uri.replace(userInfo: '', query: '', fragment: '').toString();
  } on FormatException {
    return '<无效地址>';
  }
}

String _redactApiKey(String message, String apiKey) {
  if (apiKey.isEmpty) return message;
  return message.replaceAll(apiKey, '[API Key 已隐藏]');
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _ValueSlider extends StatelessWidget {
  const _ValueSlider({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label)),
            Text(valueText, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: valueText,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }
}
