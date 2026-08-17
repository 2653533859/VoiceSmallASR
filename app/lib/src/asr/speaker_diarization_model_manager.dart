/// sherpa-onnx 离线说话人分离模型的下载、校验和缓存管理。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vsasr_app/src/asr/model_manager.dart';

const String kSpeakerSegmentationArchiveName =
    'sherpa-onnx-pyannote-segmentation-3-0.tar.bz2';
const String kSpeakerSegmentationDirectoryName =
    'sherpa-onnx-pyannote-segmentation-3-0';
const String kSpeakerSegmentationModelName = 'model.int8.onnx';
const String kSpeakerEmbeddingModelName =
    '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx';

const String kSpeakerSegmentationArchiveSha256 =
    '24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488';
const String kSpeakerSegmentationModelSha256 =
    'd582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d';
const String kSpeakerEmbeddingModelSha256 =
    '1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b';

const int kSpeakerSegmentationArchiveMinBytes = 6 * 1024 * 1024;
const int kSpeakerSegmentationModelMinBytes = 1024 * 1024;
const int kSpeakerEmbeddingModelMinBytes = 30 * 1024 * 1024;

/// 官方 release asset 名称中保留了 `recongition` 这一拼写。
const List<String> kSpeakerSegmentationBaseUrls = <String>[
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models',
  'https://ghfast.top/https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models',
  'https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models',
];

const List<String> kSpeakerEmbeddingBaseUrls = <String>[
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models',
  'https://ghfast.top/https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models',
  'https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models',
];

/// 已就绪的说话人分离模型路径。
class SpeakerDiarizationModelPaths {
  const SpeakerDiarizationModelPaths({
    required this.root,
    required this.segmentationModel,
    required this.embeddingModel,
  });

  final String root;
  final String segmentationModel;
  final String embeddingModel;

  bool get exists =>
      File(segmentationModel).existsSync() && File(embeddingModel).existsSync();
}

/// 模型下载与校验管理器。
class SpeakerDiarizationModelManager {
  SpeakerDiarizationModelManager({
    this.segmentationBaseUrls = kSpeakerSegmentationBaseUrls,
    this.embeddingBaseUrls = kSpeakerEmbeddingBaseUrls,
    String? root,
  }) : _cachedRoot = root;

  final List<String> segmentationBaseUrls;
  final List<String> embeddingBaseUrls;
  String? _cachedRoot;

  Future<String> resolveRoot() async {
    final String? cached = _cachedRoot;
    if (cached != null) return cached;
    final Directory support = await getApplicationSupportDirectory();
    final String? environmentRoot = Platform
        .environment['VSASR_SPEAKER_MODEL_DIR']
        ?.trim();
    final String root = environmentRoot == null || environmentRoot.isEmpty
        ? p.join(support.path, 'models', 'speaker_diarization')
        : environmentRoot;
    _cachedRoot = root;
    return root;
  }

  Future<SpeakerDiarizationModelPaths> resolvePaths() async {
    final String root = await resolveRoot();
    return SpeakerDiarizationModelPaths(
      root: root,
      segmentationModel: p.join(
        root,
        kSpeakerSegmentationDirectoryName,
        kSpeakerSegmentationModelName,
      ),
      embeddingModel: p.join(root, kSpeakerEmbeddingModelName),
    );
  }

  Future<bool> isReady() async => (await resolvePaths()).exists;

  Future<int> usedBytes() async {
    final Directory dir = Directory(await resolveRoot());
    if (!dir.existsSync()) return 0;
    int total = 0;
    await for (final FileSystemEntity entity in dir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<void> deleteAll() async {
    final Directory dir = Directory(await resolveRoot());
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  Future<void> verifyIntegrity(SpeakerDiarizationModelPaths paths) async {
    await _verifyFile(paths.segmentationModel, kSpeakerSegmentationModelSha256);
    await _verifyFile(paths.embeddingModel, kSpeakerEmbeddingModelSha256);
  }

  Future<SpeakerDiarizationModelPaths> ensure({
    bool allowDownload = true,
    ModelProgress? progress,
  }) async {
    final SpeakerDiarizationModelPaths paths = await resolvePaths();
    if (paths.exists) {
      try {
        await verifyIntegrity(paths);
        return paths;
      } on Object catch (error) {
        if (!allowDownload) {
          throw StateError('说话人模型完整性校验失败：$error');
        }
        await _removeInvalidFiles(paths);
      }
    }
    if (!allowDownload) {
      throw StateError('说话人模型不完整且已禁止下载。请把模型放到 ${paths.root}');
    }

    await Directory(paths.root).create(recursive: true);
    final File segmentation = File(paths.segmentationModel);
    if (!segmentation.existsSync()) {
      final File archive = File(
        p.join(paths.root, '_archives', kSpeakerSegmentationArchiveName),
      );
      if (!archive.existsSync()) {
        await _downloadWithFallback(
          kSpeakerSegmentationArchiveName,
          archive,
          segmentationBaseUrls,
          progress,
          minBytes: kSpeakerSegmentationArchiveMinBytes,
        );
      } else {
        try {
          await _verifyFile(archive.path, kSpeakerSegmentationArchiveSha256);
        } on Object {
          await archive.delete();
          await _downloadWithFallback(
            kSpeakerSegmentationArchiveName,
            archive,
            segmentationBaseUrls,
            progress,
            minBytes: kSpeakerSegmentationArchiveMinBytes,
          );
        }
      }
      progress?.call('解压说话人分离模型…', 0, 0);
      try {
        final String archivePath = archive.path;
        final String target = paths.root;
        await Isolate.run<void>(() => extractFileToDisk(archivePath, target));
      } catch (error) {
        if (archive.existsSync()) await archive.delete();
        throw Exception('解压说话人分离模型失败：$error');
      }
      if (archive.existsSync()) await archive.delete();
      final Directory archiveDir = archive.parent;
      if (archiveDir.existsSync() && archiveDir.listSync().isEmpty) {
        await archiveDir.delete();
      }
    }

    final File embedding = File(paths.embeddingModel);
    if (!embedding.existsSync()) {
      await _downloadWithFallback(
        kSpeakerEmbeddingModelName,
        embedding,
        embeddingBaseUrls,
        progress,
        minBytes: kSpeakerEmbeddingModelMinBytes,
      );
    }

    final SpeakerDiarizationModelPaths result = await resolvePaths();
    if (!result.exists) {
      throw StateError('说话人模型准备失败，请检查 ${result.root} 的内容与磁盘空间');
    }
    try {
      await verifyIntegrity(result);
    } on Object catch (error) {
      await _removeInvalidFiles(result);
      throw StateError('说话人模型完整性校验失败：$error');
    }
    progress?.call('说话人分离模型就绪', 1, 1);
    return result;
  }

  Future<void> _removeInvalidFiles(SpeakerDiarizationModelPaths paths) async {
    final Directory segmentationDir = Directory(
      p.dirname(paths.segmentationModel),
    );
    if (segmentationDir.existsSync()) {
      await segmentationDir.delete(recursive: true);
    }
    final File embedding = File(paths.embeddingModel);
    if (embedding.existsSync()) await embedding.delete();
    final File archive = File(
      p.join(paths.root, '_archives', kSpeakerSegmentationArchiveName),
    );
    if (archive.existsSync()) await archive.delete();
    final Directory archiveDir = archive.parent;
    if (archiveDir.existsSync() && archiveDir.listSync().isEmpty) {
      await archiveDir.delete();
    }
  }

  Future<void> _downloadWithFallback(
    String fileName,
    File dest,
    List<String> baseUrls,
    ModelProgress? progress, {
    required int minBytes,
  }) async {
    Object? lastError;
    for (int i = 0; i < baseUrls.length; i++) {
      try {
        await _download(
          '${baseUrls[i]}/$fileName',
          dest,
          fileName,
          i + 1,
          baseUrls.length,
          progress,
          minBytes,
        );
        return;
      } catch (error) {
        lastError = error;
        progress?.call('源 ${i + 1} 失败，换下一个镜像…', 0, 0);
      }
    }
    throw Exception('$fileName 下载失败（已尝试 ${baseUrls.length} 个源）：$lastError');
  }

  Future<void> _download(
    String url,
    File dest,
    String label,
    int sourceIndex,
    int sourceCount,
    ModelProgress? progress,
    int minBytes,
  ) async {
    await dest.parent.create(recursive: true);
    final File tmp = File('${dest.path}.part');
    if (tmp.existsSync()) await tmp.delete();

    final http.Client client = http.Client();
    try {
      final http.StreamedResponse response = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(kModelDownloadTimeout);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final int total = response.contentLength ?? 0;
      int done = 0;
      final IOSink sink = tmp.openWrite();
      final String stage = '下载 $label（源 $sourceIndex/$sourceCount）';
      try {
        await response.stream.timeout(kModelDownloadTimeout).forEach((
          List<int> chunk,
        ) {
          sink.add(chunk);
          done += chunk.length;
          progress?.call(stage, done, total);
        });
      } finally {
        await sink.close();
      }
      if (total > 0 && done != total) {
        throw Exception('$label 下载不完整：收到 $done 字节，应为 $total 字节');
      }
      if (total <= 0 && done < minBytes) {
        throw Exception(
          '$label 下载不完整：只收到 $done 字节（服务端未给出总长度，至少应有 $minBytes 字节）',
        );
      }
      await tmp.rename(dest.path);
    } catch (_) {
      if (tmp.existsSync()) await tmp.delete();
      rethrow;
    } finally {
      client.close();
    }
  }
}

Future<void> _verifyFile(String path, String expected) async {
  final File file = File(path);
  if (!await file.exists()) throw StateError('缺少模型文件：$path');
  final crypto.Digest digest = await crypto.sha256.bind(file.openRead()).first;
  if (digest.toString() != expected) {
    throw StateError('模型文件校验失败：$path');
  }
}
