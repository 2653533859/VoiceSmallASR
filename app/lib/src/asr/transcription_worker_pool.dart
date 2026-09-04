import 'dart:async';

import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/asr_engine.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';
import 'package:vsasr_app/src/asr/transcription_worker.dart';

/// 识别 Isolate 池：管理多个预加载模型的 worker，支持按需扩容与配置复用。
class TranscriptionWorkerPool {
  TranscriptionWorkerPool({
    this.maxWorkers = 1,
    this.launch = launchWorkerIsolate,
  });

  final int maxWorkers;
  final TranscriberLauncher launch;

  final List<_PoolEntry> _entries = <_PoolEntry>[];
  bool _disposed = false;
  int _generation = 0;

  /// 获取一个识别器。
  ///
  /// 1. 优先找空闲且配置一致的。
  /// 2. 其次若未达上限，启动新 worker。
  /// 3. 最后回收一个空闲但配置不一致的（销毁并重建）。
  /// 4. 如果全忙，由于任务调度器 (capacity) 的存在，理论上不应发生；
  ///    若发生了，则等待现有 worker 释放。
  Future<Transcriber> acquire({
    required AsrConfig config,
    required bool allowDownload,
    required ModelProgress onModelProgress,
  }) async {
    if (_disposed) throw StateError('TranscriptionWorkerPool 已关闭');
    final int generation = _generation;

    while (true) {
      if (_disposed || generation != _generation) {
        throw StateError('TranscriptionWorkerPool 已重置');
      }
      // 1. 找配置完全一致的空闲 worker
      for (final _PoolEntry entry in _entries) {
        if (!entry.busy && _sameConfig(entry.config, config)) {
          entry.busy = true;
          return entry.worker;
        }
      }

      // 2. 没找到一致的，看能否扩容
      if (_entries.length < maxWorkers) {
        final Transcriber worker = await launch(
          config: config,
          allowDownload: allowDownload,
          onModelProgress: onModelProgress,
        );
        if (_disposed || generation != _generation) {
          await worker.dispose();
          throw StateError('TranscriptionWorkerPool 已重置');
        }
        final _PoolEntry entry = _PoolEntry(worker, config)..busy = true;
        _entries.add(entry);
        return worker;
      }

      // 3. 已达上限，回收一个配置不符的空闲 worker
      _PoolEntry? stale;
      for (final _PoolEntry entry in _entries) {
        if (!entry.busy) {
          stale = entry;
          break;
        }
      }

      if (stale != null) {
        _entries.remove(stale);
        await stale.worker.dispose();
        // 递归尝试，下次循环会走扩容逻辑
        continue;
      }

      // 4. 全部在忙，等待某个释放（通过微任务循环或简单的延时）
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void release(Transcriber worker) {
    for (final _PoolEntry entry in _entries) {
      if (entry.worker == worker) {
        entry.busy = false;
        return;
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await clear();
  }

  /// 释放当前所有 worker，但保留池本身供后续任务重新创建 worker。
  ///
  /// 用于取消任务、切换模型配置或删除模型缓存。会让正在等待或启动中的
  /// [acquire] 以“池已重置”结束，避免迟到的 worker 留在内存中。
  Future<void> clear() async {
    _generation++;
    final List<Transcriber> toDispose = _entries
        .map((_PoolEntry e) => e.worker)
        .toList();
    _entries.clear();
    await Future.wait(toDispose.map((Transcriber w) => w.dispose()));
  }

  bool _sameConfig(AsrConfig a, AsrConfig b) {
    final VadConfig av = a.vad;
    final VadConfig bv = b.vad;
    return a.language == b.language &&
        a.numThreads == b.numThreads &&
        a.provider == b.provider &&
        a.useItn == b.useItn &&
        a.partialInterval == b.partialInterval &&
        av.threshold == bv.threshold &&
        av.minSilenceDuration == bv.minSilenceDuration &&
        av.minSpeechDuration == bv.minSpeechDuration &&
        av.maxSpeechDuration == bv.maxSpeechDuration &&
        av.windowSize == bv.windowSize;
  }
}

class _PoolEntry {
  _PoolEntry(this.worker, this.config);
  final Transcriber worker;
  final AsrConfig config;
  bool busy = false;
}
