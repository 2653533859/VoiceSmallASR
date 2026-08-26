/// Android 真机 / Windows 用户桌面 / macOS 验收入口。
///
/// 该测试不会进入普通 `flutter test`，必须在目标设备或桌面上显式运行：
///
/// ```bash
/// VSASR_DEVICE_TEST_VIDEO=/path/to/input.mp4 \
/// VSASR_DEVICE_TEST_PLAYLIST=/path/to/one.mp4\|/path/to/two.mp4 \
/// VSASR_DEVICE_TEST_REPORT=/path/to/device_acceptance_report.json \
/// flutter test integration_test/device_acceptance_test.dart -d <device-id>
/// ```
///
/// 模型缺失时会实际下载并校验；默认使用模型压缩包自带的
/// `test_wavs/yue.wav`。真实麦克风测试需要额外设置
/// `VSASR_DEVICE_TEST_MIC_SECONDS=15`，并在录音期间对着设备说话。
/// Android 上不能依赖 shell 环境变量时，用同名 `--dart-define` 传入参数。
// 首次下载约 155 MB 模型时，国内镜像的持续速度可能让 setUpAll 超过
// test_api 默认的 12 分钟 synthetic-test 超时；验收入口允许更长的准备时间。
@Timeout(Duration(minutes: 30))
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
const String _definedPlaylist = String.fromEnvironment(
  'VSASR_DEVICE_TEST_PLAYLIST',
);
const String _definedReport = String.fromEnvironment(
  'VSASR_DEVICE_TEST_REPORT',
);
const String _definedDeviceLabel = String.fromEnvironment('VSASR_DEVICE_LABEL');
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
  late AsrConfig deviceConfig;
  late Map<String, Object?> report;

  setUpAll(() async {
    models = ModelManager();
    final bool wasReady = await models.isReady();
    final Stopwatch watch = Stopwatch()..start();
    String lastProgressStage = '';
    int lastProgressBucket = -1;
    paths = await models.ensure(
      allowDownload: true,
      progress: (String stage, int done, int total) {
        final int bucket = total > 0 ? done ~/ (1024 * 1024) : done;
        final bool shouldLog =
            stage != lastProgressStage ||
            total <= 0 ||
            bucket != lastProgressBucket ||
            (total > 0 && done >= total);
        if (!shouldLog) return;
        lastProgressStage = stage;
        lastProgressBucket = bucket;
        final String suffix = total > 0 ? ' $done/$total' : '';
        _log('$stage$suffix');
      },
    );
    watch.stop();
    audioPath =
        _setting(_definedAudio, 'VSASR_DEVICE_TEST_AUDIO') ??
        p.join(p.dirname(paths.asrModel), 'test_wavs', 'yue.wav');
    deviceConfig = _deviceConfig();
    final Map<String, Object?> device = await _deviceInfo(deviceConfig);
    report = <String, Object?>{
      'schema_version': 1,
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'device_label': _setting(_definedDeviceLabel, 'VSASR_DEVICE_LABEL'),
      'platform': Platform.operatingSystem,
      'operating_system_version': Platform.operatingSystemVersion,
      'configuration': <String, Object?>{
        'language': deviceConfig.language,
        'num_threads': deviceConfig.numThreads,
      },
      'device': device,
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
      config: deviceConfig,
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
    final String? configuredVideoPath = _setting(
      _definedVideo,
      'VSASR_DEVICE_TEST_VIDEO',
    );
    final String? playlistDefinition = _setting(
      _definedPlaylist,
      'VSASR_DEVICE_TEST_PLAYLIST',
    );
    final List<String> playlistPaths = _playlistPaths(playlistDefinition);
    if (configuredVideoPath == null && playlistPaths.isEmpty) {
      markTestSkipped(
        '未提供 VSASR_DEVICE_TEST_VIDEO 或 VSASR_DEVICE_TEST_PLAYLIST',
      );
      return;
    }
    if (playlistDefinition != null) {
      expect(
        playlistPaths.length,
        greaterThanOrEqualTo(2),
        reason: 'VSASR_DEVICE_TEST_PLAYLIST 至少需要两个以 | 分隔的视频路径',
      );
      for (final String path in playlistPaths) {
        expect(File(path).existsSync(), isTrue, reason: '播放列表视频不存在：$path');
      }
    }
    final String videoPath = configuredVideoPath ?? playlistPaths.first;
    final File video = File(videoPath);
    expect(video.existsSync(), isTrue, reason: '视频不存在：$videoPath');

    _recordProcessMemory(report, 'before_video_decode');
    final Stopwatch decodeWatch = Stopwatch()..start();
    int audioSampleCount = 0;
    await for (final DecodedAudioChunk chunk
        in const PlatformAudioDecoder().decodeFileChunks(
          videoPath,
          chunkDuration: const Duration(seconds: 30),
        )) {
      audioSampleCount += chunk.samples.length;
    }
    decodeWatch.stop();
    _recordProcessMemory(report, 'after_video_decode');
    expect(audioSampleCount, greaterThan(0), reason: '视频没有可供原生解码的音轨');

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
        'audio_sample_count': audioSampleCount,
        'audio_decode_elapsed_ms': decodeWatch.elapsedMilliseconds,
        'open_elapsed_ms': openWatch.elapsedMilliseconds,
        'duration_seconds': duration.inMilliseconds / 1000,
      };
      if (playlistPaths.isNotEmpty) {
        final List<Map<String, Object?>> openedItems = <Map<String, Object?>>[];
        final Iterable<String> pathsToSwitch = playlistPaths.first == videoPath
            ? playlistPaths.skip(1)
            : playlistPaths;
        for (final String path in pathsToSwitch) {
          final Stopwatch playlistOpenWatch = Stopwatch()..start();
          await player.open(path);
          await _waitUntil(
            () =>
                player.filePath == path &&
                player.duration > const Duration(seconds: 1),
            reason: '播放列表视频未能切换或读取时长：$path',
          );
          playlistOpenWatch.stop();
          openedItems.add(<String, Object?>{
            'path': path,
            'open_elapsed_ms': playlistOpenWatch.elapsedMilliseconds,
            'duration_seconds': player.duration.inMilliseconds / 1000,
          });
        }
        report['video_playlist'] = <String, Object?>{
          'paths': playlistPaths,
          'switched_count': openedItems.length,
          'opened_items': openedItems,
        };
      }
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
    final Map<String, Object?> configuration =
        report['configuration']! as Map<String, Object?>;
    configuration['max_live_rtf'] = maxRtf;
    configuration['microphone_seconds'] = seconds;
    _recordProcessMemory(report, 'before_microphone_worker');
    final TranscriptionWorker worker = await TranscriptionWorker.start(
      config: deviceConfig,
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
    final Stopwatch watch = Stopwatch();
    try {
      final Stream<Float32List> audio = await microphone.start();
      // 权限请求可能弹出系统对话框；不把用户授权等待时间计入实时 RTF。
      watch.start();
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

List<String> _playlistPaths(String? definition) {
  if (definition == null) return <String>[];
  return definition
      .split('|')
      .map((String path) => path.trim())
      .where((String path) => path.isNotEmpty)
      .toList(growable: false);
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

Future<Map<String, Object?>> _deviceInfo(AsrConfig config) async =>
    <String, Object?>{
      'architecture': await _architecture(),
      'logical_processor_count': Platform.numberOfProcessors,
      'physical_memory_bytes': await _physicalMemoryBytes(),
      'recommended_threads': config.numThreads,
    };

Future<int?> _physicalMemoryBytes() async {
  if (Platform.isMacOS) {
    final String? value = await _commandOutput('sysctl', <String>[
      '-n',
      'hw.memsize',
    ]);
    return value == null ? null : int.tryParse(value);
  }
  if (Platform.isAndroid) {
    try {
      final String content = await File('/proc/meminfo').readAsString();
      final RegExpMatch? match = RegExp(
        r'^MemTotal:\s+(\d+)\s+kB$',
        multiLine: true,
      ).firstMatch(content);
      final int? kibibytes = match == null
          ? null
          : int.tryParse(match.group(1)!);
      return kibibytes == null ? null : kibibytes * 1024;
    } on Object {
      return null;
    }
  }
  if (Platform.isWindows) {
    final String? value = await _commandOutput('powershell', <String>[
      '-NoProfile',
      '-Command',
      '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory',
    ]);
    return value == null ? null : int.tryParse(value);
  }
  return null;
}

Future<String?> _architecture() async {
  if (Platform.isWindows) {
    return Platform.environment['PROCESSOR_ARCHITEW6432'] ??
        Platform.environment['PROCESSOR_ARCHITECTURE'];
  }
  return await _commandOutput('uname', <String>['-m']) ??
      Platform.environment['PROCESSOR_ARCHITECTURE'];
}

Future<String?> _commandOutput(
  String executable,
  List<String> arguments,
) async {
  try {
    final ProcessResult result = await Process.run(executable, arguments);
    if (result.exitCode != 0) return null;
    final String output = result.stdout.toString().trim();
    return output.isEmpty ? null : output;
  } on Object {
    return null;
  }
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
