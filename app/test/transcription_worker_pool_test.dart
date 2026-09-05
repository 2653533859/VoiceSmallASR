import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/transcription_worker_pool.dart';

import 'support/fake_asr.dart';

void main() {
  test('非正容量在运行时拒绝', () {
    expect(() => TranscriptionWorkerPool(maxWorkers: 0), throwsArgumentError);
    expect(() => TranscriptionWorkerPool(maxWorkers: -1), throwsArgumentError);
  });

  for (final String action in <String>['discard', 'clear', 'stale']) {
    test('$action 销毁未完成时继续计入容量且销毁幂等', () async {
      final Completer<void> gate = Completer<void>();
      final _BlockingTranscriber worker = _BlockingTranscriber(gate);
      int launches = 0;
      final TranscriptionWorkerPool pool = TranscriptionWorkerPool(
        launch:
            ({
              required AsrConfig config,
              required bool allowDownload,
              required ModelProgress onModelProgress,
            }) async {
              return launches++ == 0 ? worker : FakeTranscriber();
            },
      );
      addTearDown(pool.dispose);
      Future<Transcriber> acquire({String language = 'auto'}) => pool.acquire(
        config: AsrConfig(language: language),
        allowDownload: false,
        onModelProgress: (_, _, _) {},
      );
      await acquire();
      Future<void>? retiring;
      Future<Transcriber>? replacing;
      if (action == 'clear') {
        retiring = pool.clear();
      } else if (action == 'discard') {
        retiring = pool.discard(worker);
      } else {
        pool.release(worker);
        replacing = acquire(language: 'en');
      }
      final Future<void> duplicate = pool.discard(worker);
      final Future<Transcriber> waiting = acquire();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(launches, 1);
      expect(worker.disposeCalls, 1);
      gate.complete();
      await retiring;
      await duplicate;
      if (replacing != null) pool.release(await replacing);
      pool.release(await waiting);
      await pool.discard(worker);
      expect(worker.disposeCalls, 1);
    });
  }

  test('并发冷启动计入容量，释放后复用同一个 worker', () async {
    final Completer<Transcriber> gate = Completer<Transcriber>();
    int launches = 0;
    final TranscriptionWorkerPool pool = TranscriptionWorkerPool(
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) {
            launches++;
            return gate.future;
          },
    );
    addTearDown(pool.dispose);
    Future<Transcriber> acquire() => pool.acquire(
      config: AsrConfig(),
      allowDownload: false,
      onModelProgress: (_, _, _) {},
    );
    final Future<Transcriber> first = acquire();
    final Future<Transcriber> second = acquire();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(launches, 1);
    final FakeTranscriber worker = FakeTranscriber();
    gate.complete(worker);
    expect(await first, same(worker));
    pool.release(worker);
    expect(await second, same(worker));
    expect(launches, 1);
  });

  test('启动失败释放占位，坏 worker 移除后不复用', () async {
    int launches = 0;
    final TranscriptionWorkerPool pool = TranscriptionWorkerPool(
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            if (launches++ == 0) throw StateError('启动失败');
            return FakeTranscriber();
          },
    );
    addTearDown(pool.dispose);
    Future<Transcriber> acquire() => pool.acquire(
      config: AsrConfig(),
      allowDownload: false,
      onModelProgress: (_, _, _) {},
    );
    await expectLater(acquire(), throwsStateError);
    final Transcriber bad = await acquire();
    await pool.discard(bad);
    pool.release(bad);
    expect(await acquire(), isNot(same(bad)));
    expect(launches, 3);
  });

  test('清空池会等待 worker 释放，并允许后续重新创建', () async {
    final Completer<void> disposeGate = Completer<void>();
    final _BlockingTranscriber first = _BlockingTranscriber(disposeGate);
    final FakeTranscriber second = FakeTranscriber();
    int launches = 0;
    final TranscriptionWorkerPool pool = TranscriptionWorkerPool(
      launch: ({
        required AsrConfig config,
        required bool allowDownload,
        required ModelProgress onModelProgress,
      }) async => launches++ == 0 ? first : second,
    );
    addTearDown(pool.dispose);

    final Transcriber acquired = await pool.acquire(
      config: AsrConfig(),
      allowDownload: false,
      onModelProgress: (_, _, _) {},
    );
    pool.release(acquired);

    final Future<void> clearing = pool.clear();
    await Future<void>.delayed(Duration.zero);
    expect(first.disposed, isTrue);
    var cleared = false;
    unawaited(clearing.then((_) => cleared = true));
    await Future<void>.delayed(Duration.zero);
    expect(cleared, isFalse);

    disposeGate.complete();
    await clearing;
    final Transcriber recreated = await pool.acquire(
      config: AsrConfig(),
      allowDownload: false,
      onModelProgress: (_, _, _) {},
    );
    expect(recreated, same(second));
    expect(launches, 2);
    pool.release(recreated);
  });

  test('加载中的 worker 在池清空后到达时会被释放', () async {
    final Completer<void> launchGate = Completer<void>();
    final FakeTranscriber worker = FakeTranscriber();
    var launched = false;
    final TranscriptionWorkerPool pool = TranscriptionWorkerPool(
      launch:
          ({
            required AsrConfig config,
            required bool allowDownload,
            required ModelProgress onModelProgress,
          }) async {
            launched = true;
            await launchGate.future;
            return worker;
          },
    );
    addTearDown(pool.dispose);

    final Future<Transcriber> acquiring = pool.acquire(
      config: AsrConfig(),
      allowDownload: false,
      onModelProgress: (_, _, _) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(launched, isTrue);

    final Future<void> clearing = pool.clear();
    launchGate.complete();
    await clearing;
    await expectLater(acquiring, throwsA(isA<StateError>()));
    expect(worker.disposed, isTrue);
  });
}

class _BlockingTranscriber extends FakeTranscriber {
  _BlockingTranscriber(this._disposeGate);

  final Completer<void> _disposeGate;
  int disposeCalls = 0;

  @override
  Future<void> dispose() async {
    disposed = true;
    disposeCalls++;
    await _disposeGate.future;
  }
}
