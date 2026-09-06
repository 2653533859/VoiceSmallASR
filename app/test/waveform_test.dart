import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/audio/audio_decoder.dart';
import 'package:vsasr_app/src/audio/waveform.dart';

class WaveDecoder implements ResumableChunkedAudioDecoder {
  Duration? start;
  bool closed = false;
  int chunks = 0;
  @override
  Stream<DecodedAudioChunk> decodeFileChunksFrom(
    String path, {
    required Duration startAt,
    Duration chunkDuration = const Duration(seconds: 10),
  }) async* {
    start = startAt;
    try {
      for (int i = 0; i < 100; i++) {
        chunks++;
        yield DecodedAudioChunk(
          Float32List.fromList(
            List.generate(16000, (j) => j < 8000 ? -.25 : .75),
          ),
          isLast: false,
        );
      }
    } finally {
      closed = true;
    }
  }
}

void main() {
  test('只读取可见范围、聚合绝对峰值、提前结束释放解码流', () async {
    final decoder = WaveDecoder();
    final data = await loadWaveform(
      path: '/test',
      start: 45,
      duration: 2,
      bins: 4,
      decoder: decoder,
    );
    expect(decoder.start, const Duration(seconds: 45));
    expect(data.peaks, [.25, .75, .25, .75]);
    expect(data.decodedSeconds, 2);
    expect(decoder.chunks, 2);
    expect(decoder.closed, isTrue);
  });
  test('取消后释放解码会话且不继续扫描文件', () async {
    final decoder = WaveDecoder();
    await loadWaveform(
      path: '/test',
      start: 0,
      duration: 120,
      decoder: decoder,
      isCancelled: () => decoder.chunks > 1,
    );
    expect(decoder.chunks, 2);
    expect(decoder.closed, isTrue);
  });
  test('拒绝无界或无效窗口', () async {
    await expectLater(
      loadWaveform(path: '/test', start: 0, duration: 121),
      throwsArgumentError,
    );
    await expectLater(
      loadWaveform(path: '/test', start: double.nan, duration: 30),
      throwsArgumentError,
    );
  });
}
