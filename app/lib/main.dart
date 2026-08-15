import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final AppSettingsRepository settings = AppSettingsRepository();
  AsrConfig config = AsrConfig();
  bool offlineMode = false;
  try {
    config = await settings.loadConfig(fallback: config);
    offlineMode = await settings.loadOfflineMode();
  } on Object {
    // 偏好存储不可用时仍以默认配置启动，设置页会继续提供重试机会。
  }
  runApp(
    VsasrApp(
      initialConfig: config,
      initialOfflineMode: offlineMode,
      settings: settings,
    ),
  );
}
