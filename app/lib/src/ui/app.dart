/// 应用外壳：主题与首页。
library;

import 'package:flutter/material.dart';
import 'package:vsasr_app/src/ui/home_page.dart';
import 'package:vsasr_app/src/ui/live_controller.dart';
import 'package:vsasr_app/src/ui/transcribe_controller.dart';

/// 顶层 Widget。[controller] / [live] 只在测试里显式传入。
class VsasrApp extends StatefulWidget {
  const VsasrApp({super.key, this.controller, this.live});

  final TranscribeController? controller;
  final LiveController? live;

  @override
  State<VsasrApp> createState() => _VsasrAppState();
}

class _VsasrAppState extends State<VsasrApp> {
  late final TranscribeController _controller = widget.controller ?? TranscribeController();
  late final bool _ownsController = widget.controller == null;

  /// 实时字幕借用同一个识别 worker：模型 240 MB，不能加载两份。
  late final LiveController _live =
      widget.live ??
      LiveController(
        provideWorker: _controller.ensureWorker,
        languageOf: () => _controller.language,
      );
  late final bool _ownsLive = widget.live == null;

  @override
  void dispose() {
    // 先收实时会话再关 worker：会话活在 worker 的 isolate 里。
    if (_ownsLive) _live.dispose();
    if (_ownsController) _controller.dispose();
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
      home: HomePage(controller: _controller, live: _live),
    );
  }
}
