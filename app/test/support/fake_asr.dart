/// UI 层测试用的替身：不加载原生库、不碰真模型、不起 isolate。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/asr/streaming_transcriber.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/audio/microphone.dart';

/// 进程内的假转写器：把采样数换算成一段固定结果，并按秒回报进度。
class FakeTranscriber implements Transcriber {
  FakeTranscriber({this.language = 'auto', this.text = '呢几个字都表达唔到', this.liveFailure});

  final String language;
  final String text;

  /// 非空时 [startLive] 抛出它，用来测「麦克风开不起来」。
  final Object? liveFailure;

  /// 收到过几次 transcribe 调用。
  int calls = 0;
  bool disposed = false;

  /// 最近一次开出的实时会话。
  FakeLiveSession? live;

  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    TranscribeProgress? onProgress,
  }) async {
    calls++;
    for (int done = kSampleRate; done <= samples.length; done += kSampleRate) {
      onProgress?.call(done, samples.length);
    }
    final double span = samples.length / kSampleRate;
    return TranscriptionResult(
      segments: <Segment>[
        Segment(
          text: text,
          start: 0.0,
          end: span,
          words: <Word>[Word(text: text, start: 0.0, end: span)],
          language: language,
          index: 0,
        ),
      ],
      duration: span,
      language: language,
    );
  }

  @override
  Future<LiveSession> startLive() async {
    final Object? failure = liveFailure;
    if (failure != null) throw failure;
    return live = FakeLiveSession();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 假实时会话：测试自己往里塞段，用来驱动界面。
class FakeLiveSession implements LiveSession {
  final StreamController<Segment> _out = StreamController<Segment>.broadcast();

  /// 收到过的音频块。
  final List<Float32List> chunks = <Float32List>[];
  bool finished = false;

  /// 停录时补出来的尾句，模拟 flush。
  Segment? tail;

  @override
  Stream<Segment> get segments => _out.stream;

  @override
  void accept(Float32List chunk) => chunks.add(chunk);

  /// 从「引擎侧」推一段结果出来。
  void emit(Segment segment) => _out.add(segment);

  /// 模拟识别链路出错。
  void fail(Object error) => _out.addError(error);

  @override
  Future<void> finish() async {
    if (finished) return;
    finished = true;
    final Segment? last = tail;
    if (last != null) _out.add(last);
    await _out.close();
  }
}

/// 假麦克风：测试自己往里推音频块。
///
/// 每次 [start] 换一个新的流控制器 —— 真的 `MicrophoneSource` 也是每场录音换一个
/// 录音器；替身不跟着做的话，「停止后再开一场」这条路径在测试里就是假的。
class FakeMicrophone implements AudioSource {
  FakeMicrophone({this.failure});

  /// 非空时 [start] 抛出它（无权限、没设备）。
  final Object? failure;

  StreamController<Float32List> _out = StreamController<Float32List>();

  /// 开过几场。
  int starts = 0;
  bool started = false;
  bool stopped = false;

  @override
  Future<Stream<Float32List>> start() async {
    final Object? error = failure;
    if (error != null) throw error;
    await stop();
    _out = StreamController<Float32List>();
    starts++;
    started = true;
    stopped = false;
    return _out.stream;
  }

  /// 推一块音频给控制器。
  void push(Float32List chunk) => _out.add(chunk);

  /// 采集链路出错（设备被拔掉等）。
  void fail(Object error) => _out.addError(error);

  @override
  Future<void> stop() async {
    stopped = true;
    // 不能 await：没人监听时 close() 的 Future 永远不会完成，
    // 而「设备没开起来就收尾」正是要测的路径之一。
    if (!_out.isClosed) unawaited(_out.close());
  }
}

/// 假解码器：要么回一段固定采样，要么抛出解码失败。
class FakeDecoder implements AudioDecoder {
  FakeDecoder({int samples = kSampleRate, this.failure}) : _samples = Float32List(samples);

  final Float32List _samples;

  /// 非空时 [decodeFile] 抛出它。
  final AudioDecodeException? failure;

  /// 被解码过的路径，按调用顺序。
  final List<String> decoded = <String>[];

  @override
  Future<Float32List> decodeFile(String path) async {
    decoded.add(path);
    final AudioDecodeException? error = failure;
    if (error != null) throw error;
    return _samples;
  }
}

/// 在 [root] 下造出能让 `ModelManager.isReady()` 为真的占位文件。
void writeFakeModel(String root) {
  final Directory asrDir = Directory(p.join(root, kAsrModelName))..createSync(recursive: true);
  File(p.join(asrDir.path, 'model.int8.onnx')).writeAsStringSync('fake');
  File(p.join(asrDir.path, 'tokens.txt')).writeAsStringSync('fake');
  File(p.join(root, kVadModelName)).writeAsStringSync('fake');
}
