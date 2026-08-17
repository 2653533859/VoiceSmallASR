/// 模型下载与本地缓存管理。对应 Python 端 `voice_small_asr/models.py`。
///
/// 首次运行需联网下载，之后完全离线。三端的存放位置都取
/// [getApplicationSupportDirectory]，Android 上位于应用私有目录，
/// 卸载即清理，不需要存储权限。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// SenseVoice-Small int8：中/英/粤/日/韩，开启 ITN 时带标点。
///
/// 固定用 2024-07-17 版而非 2025-09-09：后者不支持标点，无法用于字幕。
const String kAsrModelName =
    'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17';

/// 识别模型压缩包（约 155 MB，解压后 240 MB）。
const String kAsrArchiveName = '$kAsrModelName.tar.bz2';

/// silero-vad 单文件模型（约 630 KB）。
const String kVadModelName = 'silero_vad.onnx';

/// 完整文件的保守下限（字节），与 Python 端 `ModelSpec.min_bytes` 同源。
///
/// 镜像源是流式代理，常用 chunked 编码而不给 `Content-Length`，那时按长度
/// 比对的校验形同虚设，只能靠这个下限拦住「下了一半断线」的文件。
const int kAsrArchiveMinBytes = 100 * 1024 * 1024; // 压缩包实测约 155 MB
const int kVadModelMinBytes = 512 * 1024; // 实测 643854 字节

/// 解压后的固定模型文件 SHA-256。下载源只负责传输，最终加载前仍要校验内容。
const String kAsrModelSha256 =
    'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51';
const String kTokensSha256 =
    'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc';
const String kVadModelSha256 =
    '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6';

/// 连接或响应流连续无数据这么久就切换下一个下载源。
const Duration kModelDownloadTimeout = Duration(seconds: 60);

/// 下载源。国内直连 github.com 常超时（flutter doctor 已报错），
/// 因此按顺序尝试多个源，任一成功即可。
const List<String> kModelBaseUrls = <String>[
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models',
  'https://ghfast.top/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models',
  'https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models',
];

/// 下载/解压进度回调。[total] 为 0 表示总量未知。
typedef ModelProgress = void Function(String stage, int done, int total);

/// 已就绪的模型文件路径。
class ModelPaths {
  const ModelPaths({
    required this.root,
    required this.asrModel,
    required this.tokens,
    required this.vadModel,
  });

  /// 模型根目录。
  final String root;

  /// SenseVoice int8 onnx。
  final String asrModel;

  /// tokens.txt。
  final String tokens;

  /// silero_vad.onnx。
  final String vadModel;

  bool get exists =>
      File(asrModel).existsSync() &&
      File(tokens).existsSync() &&
      File(vadModel).existsSync();
}

/// 模型管理器：解析路径、检查就绪、按需下载。
class ModelManager {
  ModelManager({this.baseUrls = kModelBaseUrls, String? root})
    : _cachedRoot = root;

  final List<String> baseUrls;

  String? _cachedRoot;

  /// 模型根目录，首次调用时解析并缓存。
  ///
  /// 构造时传了 `root` 就直接用它（测试与「设置页指定模型目录」都靠这个），
  /// 否则取应用私有目录下的 `models`。桌面端集成测试可用
  /// `VSASR_MODEL_DIR` 指向 CI 准备好的外部模型目录，避免把模型复制进应用沙盒。
  Future<String> resolveRoot() async {
    final String? cached = _cachedRoot;
    if (cached != null) return cached;
    final Directory support = await getApplicationSupportDirectory();
    final String? environmentRoot = Platform.environment['VSASR_MODEL_DIR']
        ?.trim();
    final String root = environmentRoot == null || environmentRoot.isEmpty
        ? p.join(support.path, 'models')
        : environmentRoot;
    _cachedRoot = root;
    return root;
  }

  /// 推导模型文件应在的路径，不检查是否存在。
  Future<ModelPaths> resolvePaths() async {
    final String root = await resolveRoot();
    final String asrDir = p.join(root, kAsrModelName);
    return ModelPaths(
      root: root,
      asrModel: p.join(asrDir, 'model.int8.onnx'),
      tokens: p.join(asrDir, 'tokens.txt'),
      vadModel: p.join(root, kVadModelName),
    );
  }

  /// 模型是否已完整存在于本地。
  Future<bool> isReady() async => (await resolvePaths()).exists;

  /// 校验模型文件内容，防止截断、损坏或代理源返回错误文件。
  Future<void> verifyIntegrity(ModelPaths paths) async {
    await _verifyFile(paths.asrModel, kAsrModelSha256);
    await _verifyFile(paths.tokens, kTokensSha256);
    await _verifyFile(paths.vadModel, kVadModelSha256);
  }

  /// 已占用的磁盘空间（字节），用于设置页展示。
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

  /// 删除本地模型，供设置页「清理模型」使用。
  Future<void> deleteAll() async {
    final Directory dir = Directory(await resolveRoot());
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  Future<void> _removeInvalidFiles(ModelPaths paths) async {
    final Directory asrDir = Directory(p.dirname(paths.asrModel));
    if (asrDir.existsSync()) await asrDir.delete(recursive: true);
    final File vad = File(paths.vadModel);
    if (vad.existsSync()) await vad.delete();
    final File archive = File(p.join(paths.root, '_archives', kAsrArchiveName));
    if (archive.existsSync()) await archive.delete();
    final Directory archiveDir = archive.parent;
    if (archiveDir.existsSync() && archiveDir.listSync().isEmpty) {
      await archiveDir.delete();
    }
  }

  /// 依次尝试各下载源，任一成功即返回；全部失败则抛出最后一个错误。
  Future<void> _downloadWithFallback(
    String fileName,
    File dest,
    ModelProgress? progress, {
    required int minBytes,
  }) async {
    Object? lastError;
    for (int i = 0; i < baseUrls.length; i++) {
      final String url = '${baseUrls[i]}/$fileName';
      try {
        await _download(
          url,
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
      // 连接中途断开时 stream 会正常结束而不报错，必须比对长度，
      // 否则截断的文件会被当成有效缓存，之后永远不再重新下载。
      if (total > 0 && done != total) {
        throw Exception('$label 下载不完整：收到 $done 字节，应为 $total 字节');
      }
      // 镜像走 chunked 编码时没有 Content-Length，上面那条校验形同虚设，
      // 退回保守下限。VAD 模型尤其要紧：它没有解压环节兜底，
      // 一旦半截文件被装成缓存，之后每次运行都加载失败。
      if (total <= 0 && minBytes > 0 && done < minBytes) {
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

  /// 确保模型就绪并返回路径；缺失时按需下载。
  ///
  /// [allowDownload] 为 false 时缺模型直接抛错，用于「离线部署」场景。
  Future<ModelPaths> ensure({
    bool allowDownload = true,
    ModelProgress? progress,
  }) async {
    final ModelPaths paths = await resolvePaths();
    if (paths.exists) {
      try {
        await verifyIntegrity(paths);
        return paths;
      } on Object catch (error) {
        if (!allowDownload) {
          throw StateError('模型完整性校验失败：$error');
        }
        await _removeInvalidFiles(paths);
      }
    }
    if (!allowDownload) {
      throw StateError('模型不完整且已禁止下载。请把模型放到 ${paths.root}');
    }

    final Directory root = Directory(paths.root);
    await root.create(recursive: true);

    // 识别模型：压缩包下载 + 解压
    if (!File(paths.asrModel).existsSync() ||
        !File(paths.tokens).existsSync()) {
      final File archive = File(
        p.join(paths.root, '_archives', kAsrArchiveName),
      );
      if (!archive.existsSync()) {
        await _downloadWithFallback(
          kAsrArchiveName,
          archive,
          progress,
          minBytes: kAsrArchiveMinBytes,
        );
      }
      progress?.call('解压识别模型…', 0, 0);
      try {
        // 240 MB 的模型解压必须放到 isolate 里做流式落盘，
        // 否则会阻塞 UI 线程，且一次性读进内存在手机上容易 OOM。
        final String archivePath = archive.path;
        final String target = paths.root;
        await Isolate.run<void>(() => extractFileToDisk(archivePath, target));
      } catch (error) {
        // 坏压缩包必须删掉，否则上面的 existsSync() 会一直复用它，
        // 之后每次运行都以同样的方式失败。
        if (archive.existsSync()) await archive.delete();
        throw Exception('解压识别模型失败：$error');
      }
      if (archive.existsSync()) await archive.delete();
      final Directory archiveDir = archive.parent;
      if (archiveDir.existsSync() && archiveDir.listSync().isEmpty) {
        await archiveDir.delete();
      }
    }

    // VAD：单文件，直接下载
    final File vad = File(paths.vadModel);
    if (!vad.existsSync()) {
      await _downloadWithFallback(
        kVadModelName,
        vad,
        progress,
        minBytes: kVadModelMinBytes,
      );
    }

    final ModelPaths result = await resolvePaths();
    if (!result.exists) {
      throw StateError('模型准备失败，请检查 ${result.root} 的内容与磁盘空间');
    }
    try {
      await verifyIntegrity(result);
    } on Object catch (error) {
      await _removeInvalidFiles(result);
      throw StateError('模型完整性校验失败：$error');
    }
    progress?.call('模型就绪', 1, 1);
    return result;
  }
}

Future<void> _verifyFile(String path, String expected) async {
  final File file = File(path);
  if (!await file.exists()) {
    throw StateError('缺少模型文件：$path');
  }
  final crypto.Digest digest = await crypto.sha256.bind(file.openRead()).first;
  final String actual = digest.toString();
  if (actual != expected) {
    throw StateError('模型文件校验失败：$path');
  }
}
