/// 应用外壳：主题与首页。
library;

import 'package:flutter/material.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/ui/home_page.dart';
import 'package:vsasr_app/src/ui/live_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';
import 'package:vsasr_app/src/translation/api_provider.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

/// 顶层 Widget。[controller] / [live] 只在测试里显式传入。
class VsasrApp extends StatefulWidget {
  const VsasrApp({
    super.key,
    this.controller,
    this.live,
    this.initialConfig,
    this.initialOfflineMode = false,
    this.settings,
    this.translationProviderResolver,
  });

  final TranscribeController? controller;
  final LiveController? live;
  final AsrConfig? initialConfig;
  final bool initialOfflineMode;
  final AppSettingsRepository? settings;
  final TranslationProviderResolver? translationProviderResolver;

  @override
  State<VsasrApp> createState() => _VsasrAppState();
}

class _VsasrAppState extends State<VsasrApp> {
  late final TranscribeController _controller =
      widget.controller ??
      TranscribeController(
        config: widget.initialConfig,
        offlineMode: widget.initialOfflineMode,
      );
  late final bool _ownsController = widget.controller == null;

  /// 实时字幕借用同一个识别 worker：模型 240 MB，不能加载两份。
  late final LiveController _live =
      widget.live ??
      LiveController(
        provideWorker: _controller.ensureWorker,
        languageOf: () => _controller.language,
        provideTranslationProvider:
            widget.translationProviderResolver ?? _loadTranslationProvider,
      );
  late final bool _ownsLive = widget.live == null;
  late final VideoPlaybackController _video = VideoPlaybackController();

  Future<TranslationProvider?> _loadTranslationProvider() async {
    final AppSettingsRepository repository =
        widget.settings ?? AppSettingsRepository();
    final String? apiKey = await repository.translationSecrets.readApiKey();
    if (apiKey == null) return null;
    final TranslationApiSettings settings = await repository
        .loadTranslationApiSettings();
    _live.setTranslationTargetLanguage(settings.targetLanguage);
    return ApiTranslationProvider(
      apiKey: apiKey,
      endpoint: settings.endpoint,
      model: settings.model,
    );
  }

  @override
  void dispose() {
    // 先收实时会话再关 worker：会话活在 worker 的 isolate 里。
    if (_ownsLive) _live.dispose();
    if (_ownsController) _controller.dispose();
    _video.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceSmallASR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FEB)),
        useMaterial3: true,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: HomePage(
        controller: _controller,
        live: _live,
        video: _video,
        settings: widget.settings,
        translationProviderResolver: widget.translationProviderResolver,
      ),
    );
  }
}
