import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/audio/wav.dart';

import 'support/wav_builder.dart';

void main() {
  late Directory workspace;
  setUp(() => workspace = Directory.systemTemp.createTempSync('wav_stream'));
  tearDown(() => workspace.deleteSync(recursive: true));

  for (final (int, int) encoding in <(int, int)>[
    (1, 8),
    (1, 16),
    (1, 24),
    (1, 32),
    (3, 32),
    (3, 64),
    (0xfffe, 16),
  ]) {
    for (final int rate in <int>[8000, 16000, 44100, 48000]) {
      test('分块与全量完全一致: $encoding / $rate Hz', () async {
        final Uint8List bytes = buildWav(
          frames: List<List<double>>.generate(
            9001,
            (int i) => <double>[(i % 127 - 63) / 64, (i % 31 - 15) / 16],
          ),
          sampleRate: rate,
          format: encoding.$1,
          bitsPerSample: encoding.$2,
          extraChunks: filler('JUNK', 3),
        );
        final File file = File('${workspace.path}/test.wav')
          ..writeAsBytesSync(bytes);
        final Float32List expected = decodeWavToModelInput(bytes);
        for (final int start in <int>[
          0,
          177,
          expected.length,
          expected.length + 1,
        ]) {
          final List<WavAudioChunk> chunks = await decodeWavFileChunks(
            file,
            chunkSamples: 137,
            startSample: start,
          ).toList();
          expect(
            chunks.expand((WavAudioChunk c) => c.samples),
            expected.skip(start),
          );
          if (chunks.isNotEmpty) {
            expect(chunks.last.isLast, isTrue);
            expect(
              chunks
                  .take(chunks.length - 1)
                  .every((WavAudioChunk c) => !c.isLast),
              isTrue,
            );
            expect(
              chunks.every((WavAudioChunk c) => c.samples.length <= 137),
              isTrue,
            );
          }
        }
      });
    }
  }

  for (final int size in <int>[0, 0xffffffff]) {
    test('流式 data 长度 $size', () async {
      final Uint8List bytes = buildWav(
        frames: List<List<double>>.generate(71, (int i) => <double>[i / 100]),
        dataSizeOverride: size,
      );
      final File file = File('${workspace.path}/size.wav')
        ..writeAsBytesSync(bytes);
      final List<WavAudioChunk> chunks = await decodeWavFileChunks(
        file,
        chunkSamples: 16,
      ).toList();
      expect(
        chunks.expand((WavAudioChunk c) => c.samples),
        decodeWavToModelInput(bytes),
      );
    });
  }

  test('大文件首块只读取固定窗口，取消会关闭文件', () async {
    final File file = File('${workspace.path}/large.wav');
    final Uint8List header = buildWav(
      frames: <List<double>>[],
      dataSizeOverride: 0xffffffff,
    );
    file.writeAsBytesSync(header);
    final RandomAccessFile large = file.openSync(mode: FileMode.append);
    // 稀疏文件避免测试本身分配大数组。
    large.truncateSync(128 * 1024 * 1024);
    large.closeSync();
    final _TrackedFile tracked = _TrackedFile(file);
    final StreamIterator<WavAudioChunk> iterator =
        StreamIterator<WavAudioChunk>(
          decodeWavFileChunks(tracked, chunkSamples: 160),
        );
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.samples.length, 160);
    expect(tracked.handle.bytesRead, lessThan(65536));
    await iterator.cancel();
    expect(tracked.handle.closed, isTrue);
  });

  test('格式失败也关闭文件', () async {
    final File file = File('${workspace.path}/bad.wav')
      ..writeAsBytesSync(<int>[0]);
    final _TrackedFile tracked = _TrackedFile(file);
    await expectLater(
      decodeWavFileChunks(tracked, chunkSamples: 10).toList(),
      throwsA(isA<WavFormatException>()),
    );
    expect(tracked.handle.closed, isTrue);
  });
}

class _TrackedFile implements File {
  _TrackedFile(this.file);
  final File file;
  late _TrackedHandle handle;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      handle = _TrackedHandle(await file.open(mode: mode));
  @override
  String get path => file.path;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TrackedHandle implements RandomAccessFile {
  _TrackedHandle(this.handle);
  final RandomAccessFile handle;
  int bytesRead = 0;
  bool closed = false;
  @override
  Future<int> length() => handle.length();
  @override
  Future<RandomAccessFile> setPosition(int position) =>
      handle.setPosition(position);
  @override
  Future<Uint8List> read(int count) async {
    bytesRead += count;
    return handle.read(count);
  }

  @override
  Future<void> close() async {
    await handle.close();
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
