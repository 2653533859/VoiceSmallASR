import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/settings/app_settings.dart';
import 'package:vsasr_app/src/ui/app.dart';

const MethodChannel _filePickerChannel = MethodChannel(
  'miguelruivo.flutter.plugins.filepicker',
);

Future<void> _prepareFilePickerForPersonalMacOS() async {
  if (!Platform.isMacOS) return;
  try {
    // 个人使用包采用 ad-hoc 签名而不是沙盒签名，跳过 file_picker 的
    // App Store entitlements 预检查；文件访问仍由 macOS 原生窗口控制。
    await _filePickerChannel.invokeMethod<void>('skipEntitlementsChecks');
  } on Object {
    // 插件不可用时不阻断应用启动，后续调用仍由 file_picker 自己处理。
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await _prepareFilePickerForPersonalMacOS();
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
