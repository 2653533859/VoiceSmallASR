/// Android 真机 / Windows 用户桌面验收入口。
///
/// 该测试不会进入普通 `flutter test`，必须在目标设备或桌面上显式运行：
///
/// ```bash
/// VSASR_DEVICE_TEST_VIDEO=/path/to/input.mp4 \
/// VSASR_DEVICE_TEST_REPORT=/path/to/device_acceptance_report.json \
/// flutter test integration_test/device_acceptance_test.dart -d <device-id>
/// ```
///
/// 模型缺失时会实际下载并校验；默认使用模型压缩包自带的
/// `test_wavs/yue.wav`。真实麦克风测试需要额外设置
/// `VSASR_DEVICE_TEST_MIC_SECONDS=15`，并在录音期间对着设备说话。
/// Android 上不能依赖 shell 环境变量时，用同名 `--dart-define` 传入参数。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';
import 'package:vsasr_app/src/asr/transcription_worker.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/audio/microphone.dart';
import 'package:vsasr_app/src/video/video_playback_controller.dart';

const String _definedAudio = String.fromEnvironment('VSASR_DEVICE_TEST_AUDIO');
const String _definedVideo = String.fromEnvironment('VSASR_DEVICE_TEST_VIDEO');
const String _definedReport = String.fromEnvironment(
  'VSASR_DEVICE_TEST_REPORT',
);
const String _definedMicSeconds = String.fromEnvironment(
  'VSASR_DEVICE_TEST_MIC_SECONDS',
);
const String _definedMaxLiveRtf = String.fromEnvironment(
  'VSASR_DEVICE_MAX_LIVE_RTF',
);
const String _definedThreads = String.fromEnvironment('VSASR_DEVICE_THREADS');
const String _definedLanguage = String.fromEnvironment('VSASR_DEVICE_LANGUAGE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late ModelManager models;
  late ModelPaths paths;
  late String audioPath;
  late Map<String, Object?> report;

  setUpAll(() async {
    models = ModelManager();
    final bool wasReady = await models.isReady();
    final Stopwatch watch = Stopwatch()..start();
    paths = await models.ensure(
      allowDownload: true,
      progress: (String stage, int done, int total) {
        final String suffix = total > 0 ? ' $done/$total' : '';
        _log('$stage$suffix');
      },
    );
    watch.stop();
    audioPath =
        _setting(_definedAudio, 'VSASR_DEVICE_TEST_AUDIO') ??
        p.join(p.dirname(paths.asrModel), 'test_wavs', 'yue.wav');
    report = <String, Object?>{
      'schema_version': 1,
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
      'operating_system_version': Platform.operatingSystemVersion,
      'process_memory': <String, Object?>{
        'source': 'dart:io ProcessInfo',
        'unit': 'bytes',
      },
      'model': <String, Object?>{
        'was_ready_before': wasReady,
        'preparation_elapsed_ms': watch.elapsedMilliseconds,
        'root': paths.root,
        'bytes': await models.usedBytes(),
      },
    };
    _recordProcessMemory(report, 'after_model_prepare');
    await _writeReport(report, paths.root);
  });

  test('模型下载、完整性校验和占用空间可记录', () async {
    expect(paths.exists, isTrue, reason: '模型未就绪：${paths.root}');
    await models.verifyIntegrity(paths);
    final int bytes = await models.usedBytes();
    expect(bytes, greaterThan(0));
    (report['model']! as Map<String, Object?>)['verified'] = true;
    (report['model']! as Map<String, Object?>)['bytes_after_tests'] = bytes;
    await _writeReport(report, paths.root);
  });

  test('真实音频识别性能记录文件 RTF', () async {
    final File audio = File(audioPath);
    if (!audio.existsSync()) {
      markTestSkipped('未找到验收音频：$audioPath');
      return;
    }
    final Stopwatch decodeWatch = Stopwatch()..start();
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(
      audioPath,
    );
    decodeWatch.stop();
    expect(samples, isNotEmpty);

    _recordProcessMemory(report, 'before_file_worker');
    final TranscriptionWorker worker = await TranscriptionWorker.start(
      config: _deviceConfig(),
      allowDownload: false,
    );
    _recordProcessMemory(report, 'after_file_worker_start');
    try {
      final Stopwatch transcriptionWatch = Stopwatch()..start();
      final TranscriptionResult result = await worker.transcribe(samples);
      transcriptionWatch.stop();
      _recordProcessMemory(report, 'after_file_transcription');
      final double? rtf = result.duration <= 0
          ? null
          : transcriptionWatch.elapsedMilliseconds / 1000 / result.duration;
      report['file_transcription'] = <String, Object?>{
        'path': audioPath,
        'sample_count': samples.length,
        'audio_duration_seconds': result.duration,
        'decode_elapsed_ms': decodeWatch.elapsedMilliseconds,
        'transcription_elapsed_ms': transcriptionWatch.elapsedMilliseconds,
        'real_time_factor': rtf,
        'segment_count': result.segments.length,
        'text': result.text,
      };
      await _writeReport(report, paths.root);
      expect(result.duration, greaterThan(0));
      expect(rtf, isNotNull);
    } finally {
      try {
        await worker.dispose();
      } finally {
        _recordProcessMemory(report, 'after_file_worker_dispose');
        await _writeReport(report, paths.root);
      }
    }
  });

  testWidgets('真实 MP4 播放和视频音轨解码性能记录', (WidgetTester tester) async {
    final String? videoPath = _setting(
      _definedVideo,
      'VSASR_DEVICE_TEST_VIDEO',
    );
    if (videoPath == null) {
      markTestSkipped('未提供 VSASR_DEVICE_TEST_VIDEO');
      return;
    }
    final File video = File(videoPath);
    expect(video.existsSync(), isTrue, reason: '视频不存在：$videoPath');

    _recordProcessMemory(report, 'before_video_decode');
    final Stopwatch decodeWatch = Stopwatch()..start();
    final Float32List samples = await const PlatformAudioDecoder().decodeFile(
      videoPath,
    );
    decodeWatch.stop();
    _recordProcessMemory(report, 'after_video_decode');
    expect(samples, isNotEmpty, reason: '视频没有可供原生解码的音轨');

    final VideoPlaybackController player = VideoPlaybackController();
    try {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: player.buildVideo())),
      );
      await tester.pump();
      final Stopwatch openWatch = Stopwatch()..start();
      await player.open(videoPath);
      await _waitUntil(
        () => player.duration > const Duration(seconds: 1),
        reason: '播放器没有从真实 MP4 读取到视频时长',
      );
      openWatch.stop();
      _recordProcessMemory(report, 'after_video_open');
      final Duration duration = player.duration;
      await player.playOrPause();
      await _waitUntil(
        () => player.position > Duration.zero,
        reason: '真实 MP4 没有开始播放',
      );
      await player.playOrPause();
      report['video_playback'] = <String, Object?>{
        'path': videoPath,
        'audio_sample_count': samples.length,
        'audio_decode_elapsed_ms': decodeWatch.elapsedMilliseconds,
        'open_elapsed_ms': openWatch.elapsedMilliseconds,
        'duration_seconds': duration.inMilliseconds / 1000,
      };
      await _writeReport(report, paths.root);
    } finally {
      player.dispose();
      _recordProcessMemory(report, 'after_video_player_dispose');
      await _writeReport(report, paths.root);
    }
  });

  test('真实麦克风实时识别不持续积压', () async {
    final double? seconds = _positiveSetting(
      _definedMicSeconds,
      'VSASR_DEVICE_TEST_MIC_SECONDS',
    );
    if (seconds == null) {
      markTestSkipped('未设置 VSASR_DEVICE_TEST_MIC_SECONDS');
      return;
    }
    final double maxRtf =
        _positiveSetting(_definedMaxLiveRtf, 'VSASR_DEVICE_MAX_LIVE_RTF') ??
        1.25;
    _recordProcessMemory(report, 'before_microphone_worker');
    final TranscriptionWorker worker = await TranscriptionWorker.start(
      config: _deviceConfig(),
      allowDownload: false,
    );
    _recordProcessMemory(report, 'after_microphone_worker_start');
    final LiveSession session = await worker.startLive();
    final MicrophoneSource microphone = MicrophoneSource();
    final List<Segment> segments = <Segment>[];
    Object? streamError;
    final StreamSubscription<Segment> segmentSubscription = session.segments
        .listen(
          segments.add,
          onError: (Object error, StackTrace stack) {
            streamError ??= error;
          },
        );
    StreamSubscription<Float32List>? audioSubscription;
    int sampleCount = 0;
    final Stopwatch watch = Stopwatch()..start();
    try {
      final Stream<Float32List> audio = await microphone.start();
      audioSubscription = audio.listen(
        (Float32List chunk) {
          sampleCount += chunk.length;
          try {
            session.accept(chunk);
          } on Object catch (error) {
            streamError ??= error;
          }
        },
        onError: (Object error, StackTrace stack) {
          streamError ??= error;
        },
      );
      await Future<void>.delayed(
        Duration(milliseconds: (seconds * 1000).round()),
      );
    } finally {
      await audioSubscription?.cancel();
      await microphone.stop();
      try {
        await session.finish();
      } finally {
        _recordProcessMemory(report, 'after_microphone_session_finish');
        watch.stop();
        await segmentSubscription.cancel();
        try {
          await worker.dispose();
        } finally {
          _recordProcessMemory(report, 'after_microphone_worker_dispose');
        }
      }
    }

    final double audioDuration = sampleCount / kSampleRate;
    final double? rtf = audioDuration <= 0
        ? null
        : watch.elapsedMilliseconds / 1000 / audioDuration;
    report['microphone'] = <String, Object?>{
      'requested_seconds': seconds,
      'audio_duration_seconds': audioDuration,
      'sample_count': sampleCount,
      'elapsed_ms': watch.elapsedMilliseconds,
      'real_time_factor': rtf,
      'max_accepted_rtf': maxRtf,
      'segment_count': segments.length,
      'sustained_backlog': rtf != null && rtf > maxRtf,
    };
    await _writeReport(report, paths.root);
    if (streamError != null) fail('实时识别失败：$streamError');
    expect(sampleCount, greaterThan(kSampleRate));
    expect(rtf, isNotNull);
    expect(
      rtf,
      lessThanOrEqualTo(maxRtf),
      reason: '实时识别持续积压，请降低线程负载或增大 VAD 分段参数',
    );
  });
}

String? _setting(String defined, String name) {
  final String value = defined.trim();
  if (value.isNotEmpty) return value;
  final String? environment = Platform.environment[name]?.trim();
  return environment == null || environment.isEmpty ? null : environment;
}

double? _positiveSetting(String defined, String name) {
  final String? value = _setting(defined, name);
  final double? parsed = value == null ? null : double.tryParse(value);
  return parsed == null || parsed <= 0 ? null : parsed;
}

void _recordProcessMemory(Map<String, Object?> report, String stage) {
  final Map<String, Object?> memory =
      report['process_memory']! as Map<String, Object?>;
  memory[stage] = <String, Object?>{
    'current_rss_bytes': _safeProcessMemory(() => ProcessInfo.currentRss),
    'max_rss_bytes': _safeProcessMemory(() => ProcessInfo.maxRss),
  };
}

int? _safeProcessMemory(int Function() read) {
  try {
    final int bytes = read();
    return bytes > 0 ? bytes : null;
  } on Object {
    return null;
  }
}

AsrConfig _deviceConfig() {
  final int threads =
      int.tryParse(_setting(_definedThreads, 'VSASR_DEVICE_THREADS') ?? '') ??
      2;
  final String language =
      _setting(_definedLanguage, 'VSASR_DEVICE_LANGUAGE') ?? 'auto';
  return AsrConfig(language: language, numThreads: threads);
}

Future<void> _writeReport(Map<String, Object?> report, String modelRoot) async {
  final String path =
      _setting(_definedReport, 'VSASR_DEVICE_TEST_REPORT') ??
      p.join(modelRoot, 'device_acceptance_report.json');
  report['updated_at'] = DateTime.now().toUtc().toIso8601String();
  final File file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  _log('验收报告：$path');
  _log(const JsonEncoder.withIndent('  ').convert(report));
}

void _log(String message) {
  // ignore: avoid_print
  print(message);
}

Future<void> _waitUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed >= timeout) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
