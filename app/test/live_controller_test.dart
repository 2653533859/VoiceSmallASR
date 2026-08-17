/// 实时字幕状态机的测试。麦克风与识别会话都是替身，
/// 不需要设备、不需要模型。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/audio/microphone.dart';
import 'package:vsasr_app/src/translation/translation_provider.dart';
import 'package:vsasr_app/src/ui/live_controller.dart';

import 'support/fake_asr.dart';

void main() {
  test('开始录音：借到 worker、开会话、开设备，状态变成录音中', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);

    expect(f.live.stage, LiveStage.idle);
    await f.live.start();

    expect(f.live.stage, LiveStage.recording);
    expect(f.live.recording, isTrue);
    expect(f.mic.started, isTrue);
    expect(f.transcriber.live, isNotNull);
    expect(f.live.statusText, contains('录音中'));
  });

  test('麦克风的音频块被转交给识别会话', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);
    await f.live.start();

    f.mic.push(Float32List(1600));
    f.mic.push(Float32List(800));
    await pumpEventQueue();

    expect(f.session.chunks.map((Float32List c) => c.length), <int>[1600, 800]);
  });

  test('局部结果原地替换，定稿结果追加', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);
    await f.live.start();

    int notified = 0;
    f.live.addListener(() => notified++);

    f.session.emit(
      const Segment(text: '今日天', start: 0.0, end: 1.0, isFinal: false),
    );
    await pumpEventQueue();
    expect(f.live.partial?.text, '今日天');
    expect(f.live.finals, isEmpty);

    // 同一句的第二条局部结果：替换而不是追加
    f.session.emit(
      const Segment(text: '今日天气', start: 0.0, end: 1.4, isFinal: false),
    );
    await pumpEventQueue();
    expect(f.live.partial?.text, '今日天气');
    expect(f.live.finals, isEmpty);

    // 定稿：进列表，局部清空
    f.session.emit(
      const Segment(text: '今日天气几好。', start: 0.0, end: 1.8, index: 0),
    );
    await pumpEventQueue();
    expect(f.live.partial, isNull);
    expect(f.live.finals.map((Segment s) => s.text), <String>['今日天气几好。']);
    expect(f.live.hasResult, isTrue);
    expect(f.live.statusText, contains('已定稿 1 句'));
    expect(notified, 3);
  });

  test('开启实时翻译后，定稿字幕异步写回译文并保持时间轴', () async {
    final _FakeLiveTranslationProvider provider =
        _FakeLiveTranslationProvider();
    int resolveCount = 0;
    final _Fixture f = _Fixture(
      translationProvider: () async {
        resolveCount++;
        return provider;
      },
    );
    addTearDown(f.dispose);
    await f.live.start();
    f.live.setTranslationEnabled(true);

    f.session.emit(
      const Segment(
        text: 'hello',
        start: 0.0,
        end: 1.0,
        language: 'en',
        index: 0,
      ),
    );
    await pumpEventQueue();

    expect(f.live.finals.single.translation, '译文：hello');
    expect(provider.from, 'en');
    expect(provider.to, 'zh-CN');
    expect(provider.calls, 1);
    expect(resolveCount, 1);
    expect(provider.closed, isFalse);

    f.session.emit(
      const Segment(
        text: 'world',
        start: 1.2,
        end: 2.0,
        language: 'en',
        index: 1,
      ),
    );
    await pumpEventQueue();
    expect(provider.calls, 2);
    expect(resolveCount, 1);

    await f.live.stop();
    expect(provider.closed, isTrue);
  });

  test('停止录音：先停设备再收会话，尾句能进来', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);
    await f.live.start();

    f.session.emit(const Segment(text: '第一句。', start: 0.0, end: 1.0, index: 0));
    // 停录时 flush 补出来的尾句 —— 往往正是用户最后说的那句话
    f.session.tail = const Segment(
      text: '最后一句。',
      start: 1.2,
      end: 2.4,
      index: 1,
    );
    await pumpEventQueue();

    await f.live.stop();

    expect(f.mic.stopped, isTrue);
    expect(f.session.finished, isTrue);
    expect(f.live.stage, LiveStage.idle);
    expect(f.live.finals.map((Segment s) => s.text), <String>['第一句。', '最后一句。']);
    expect(f.live.statusText, '已停止　共 2 句');
  });

  test('停止时清掉没定稿的局部结果，避免半句留在屏幕上', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);
    await f.live.start();

    f.session.emit(
      const Segment(text: '说到一半', start: 0.0, end: 0.8, isFinal: false),
    );
    await pumpEventQueue();
    expect(f.live.partial, isNotNull);

    await f.live.stop();
    expect(f.live.partial, isNull);
  });

  test('模型没准备好：报中文提示并回到空闲，不留下开着的设备', () async {
    final _Fixture f = _Fixture(worker: () async => null);
    addTearDown(f.dispose);

    await f.live.start();

    expect(f.live.stage, LiveStage.idle);
    expect(f.live.errorText, contains('模型未就绪'));
    expect(f.mic.started, isFalse);
  });

  test('没有麦克风权限：错误里是原生给的中文说明，会话被收掉', () async {
    final _Fixture f = _Fixture(
      mic: FakeMicrophone(
        failure: const MicrophoneException('没有麦克风权限，请在系统设置里允许'),
      ),
    );
    addTearDown(f.dispose);

    await f.live.start();

    expect(f.live.stage, LiveStage.idle);
    expect(f.live.errorText, '没有麦克风权限，请在系统设置里允许');
    // 会话是先开的，失败后必须收掉，否则下次 startLive 会被判为「已有一路在跑」
    expect(f.transcriber.live?.finished, isTrue);
  });

  test('识别链路中途出错：写进错误框并自动停录', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);
    await f.live.start();

    f.session.fail(StateError('解码炸了'));
    await pumpEventQueue();

    expect(f.live.errorText, '解码炸了');
    expect(f.live.stage, LiveStage.idle);
    expect(f.mic.stopped, isTrue);
  });

  test('采集链路出错（设备被拔掉）同样会停录', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);
    await f.live.start();

    f.mic.fail(const MicrophoneException('录音设备已断开'));
    await pumpEventQueue();

    expect(f.live.errorText, '录音设备已断开');
    expect(f.live.stage, LiveStage.idle);
  });

  test('重复 start 不会开出第二路会话', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);

    await f.live.start();
    final FakeLiveSession first = f.session;
    await f.live.start();

    expect(identical(f.transcriber.live, first), isTrue);
  });

  test('停录后可以再开一场', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);

    await f.live.start();
    await f.live.stop();
    await f.live.start();

    expect(f.live.stage, LiveStage.recording);
    expect(f.mic.starts, 2); // 第二场是重新打开设备，不是复用已关的那个
    f.mic.push(Float32List(1600));
    await pumpEventQueue();
    expect(f.session.chunks, hasLength(1)); // 新一场的音频确实还在往会话里走
  });

  test('clear 清空结果与错误；录音中不许清', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);
    await f.live.start();

    f.session.emit(const Segment(text: '一句话。', start: 0.0, end: 1.0, index: 0));
    await pumpEventQueue();

    f.live.clear(); // 录音中：不生效
    expect(f.live.finals, hasLength(1));

    await f.live.stop();
    f.live.clear();
    expect(f.live.finals, isEmpty);
    expect(f.live.hasResult, isFalse);
    expect(f.live.statusText, '');
  });

  test('导出：只含定稿句，语言取自当前选择', () async {
    final _Fixture f = _Fixture(language: () => 'yue');
    addTearDown(f.dispose);
    await f.live.start();

    f.session.emit(
      const Segment(text: '半句', start: 2.0, end: 2.5, isFinal: false),
    );
    f.session.emit(const Segment(text: '第一句。', start: 0.0, end: 1.0, index: 0));
    await pumpEventQueue();

    expect(f.live.result.language, 'yue');
    expect(f.live.result.segments.map((Segment s) => s.text), <String>['第一句。']);
    expect(f.live.result.duration, closeTo(1.0, 1e-9));

    final String srt = f.live.renderResult('srt');
    expect(srt, contains('第一句。'));
    expect(srt, isNot(contains('半句')));
  });

  test('没有结果时导出抛中文错误', () async {
    final _Fixture f = _Fixture();
    addTearDown(f.dispose);

    expect(
      () => f.live.renderResult('srt'),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('还没有'),
        ),
      ),
    );
  });

  test('shutdown 会停设备并收掉会话', () async {
    final _Fixture f = _Fixture();
    await f.live.start();

    await f.live.shutdown();

    expect(f.mic.stopped, isTrue);
    expect(f.session.finished, isTrue);
    expect(f.live.stage, LiveStage.idle);
  });

  test('dispose 之后到达的段不会触发 notifyListeners', () async {
    final _Fixture f = _Fixture();
    await f.live.start();
    final FakeLiveSession session = f.session;

    f.live.dispose();
    // 这里若不做 _disposed 保护会抛 "used after being disposed"
    session.emit(const Segment(text: '迟到的段', start: 0.0, end: 1.0, index: 0));
    await pumpEventQueue();
  });
}

/// 把「假麦克风 + 假转写器 + 控制器」这套装配收在一处。
class _Fixture {
  _Fixture({
    FakeMicrophone? mic,
    Future<Transcriber?> Function()? worker,
    String Function()? language,
    TranslationProviderResolver? translationProvider,
  }) : mic = mic ?? FakeMicrophone() {
    live = LiveController(
      provideWorker: worker ?? () async => transcriber,
      languageOf: language ?? () => 'auto',
      provideTranslationProvider: translationProvider,
      // 必须写 this.mic：构造体里的 mic 是那个可空的形参，传进去等于没传，
      // LiveController 会退回真实的 MicrophoneSource
      mic: this.mic,
    );
  }

  final FakeTranscriber transcriber = FakeTranscriber();
  late final LiveController live;
  final FakeMicrophone mic;

  /// 最近一次开出的实时会话。
  FakeLiveSession get session => transcriber.live!;

  Future<void> dispose() async {
    await live.shutdown();
    live.dispose();
  }
}

class _FakeLiveTranslationProvider implements ClosableTranslationProvider {
  String? from;
  String? to;
  bool closed = false;
  int calls = 0;

  @override
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  }) async {
    calls++;
    this.from = from;
    this.to = to;
    return texts.map((String text) => '译文：$text').toList();
  }

  @override
  void close() => closed = true;
}
