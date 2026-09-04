import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/transcription_worker_pool.dart';

import 'support/fake_asr.dart';

void main() {
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

  @override
  Future<void> dispose() async {
    disposed = true;
    await _disposeGate.future;
  }
}
