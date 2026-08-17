import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vsasr_app/src/asr/model_manager.dart';

void main() {
  test('离线模式拒绝内容校验失败的模型缓存', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'vsasr_model_test',
    );
    addTearDown(() => root.delete(recursive: true));

    final Directory asr = Directory(p.join(root.path, kAsrModelName))
      ..createSync(recursive: true);
    File(p.join(asr.path, 'model.int8.onnx')).writeAsStringSync('tampered');
    File(p.join(asr.path, 'tokens.txt')).writeAsStringSync('tampered');
    File(p.join(root.path, kVadModelName)).writeAsStringSync('tampered');

    await expectLater(
      ModelManager(root: root.path).ensure(allowDownload: false),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('完整性校验失败'),
        ),
      ),
    );
  });

  test('完整性失败时清理旧压缩包，避免重试复用坏缓存', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'vsasr_model_archive_test',
    );
    addTearDown(() => root.delete(recursive: true));

    final Directory asr = Directory(p.join(root.path, kAsrModelName))
      ..createSync(recursive: true);
    File(p.join(asr.path, 'model.int8.onnx')).writeAsStringSync('tampered');
    File(p.join(asr.path, 'tokens.txt')).writeAsStringSync('tampered');
    File(p.join(root.path, kVadModelName)).writeAsStringSync('tampered');
    final File archive = File(
      p.join(root.path, '_archives', kAsrArchiveName),
    )
      ..createSync(recursive: true)
      ..writeAsStringSync('stale archive');

    await expectLater(
      ModelManager(root: root.path, baseUrls: const <String>[]).ensure(),
      throwsA(isA<Exception>()),
    );
    expect(archive.existsSync(), isFalse);
  });
}
