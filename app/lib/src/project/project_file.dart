/// VoiceSmallASR 项目文件：媒体路径引用、识别配置和当前字幕快照。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/subtitles/subtitles.dart';

const String kProjectSchema = 'voicesmallasr.project';
const int kProjectVersion = 1;

/// 可恢复的项目快照。媒体文件只保存路径，不复制音频或视频内容。
class VsasrProject {
  const VsasrProject({
    required this.mediaPath,
    required this.config,
    required this.result,
  });

  final String? mediaPath;
  final AsrConfig config;
  final TranscriptionResult result;

  factory VsasrProject.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('项目文件根节点必须是 JSON 对象');
    }
    if (value['schema'] != kProjectSchema) {
      throw FormatException('不是 VoiceSmallASR 项目文件：${value['schema']}');
    }
    final Object? rawVersion = value['version'];
    if (rawVersion != kProjectVersion) {
      throw FormatException('不支持的项目文件版本：$rawVersion');
    }
    final Object? rawMediaPath = value['media_path'];
    if (rawMediaPath != null && rawMediaPath is! String) {
      throw const FormatException('media_path 必须是字符串或 null');
    }
    final TranscriptionResult result = TranscriptionResult.fromJson(
      value['result'],
    );
    ensureValidSubtitleTimeline(result.segments, duration: result.duration);
    return VsasrProject(
      mediaPath: rawMediaPath as String?,
      config: AsrConfig.fromJson(value['config']),
      result: result,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': kProjectSchema,
    'version': kProjectVersion,
    'media_path': mediaPath,
    'config': config.toJson(),
    'result': result.toJson(),
  };
}

/// 项目文件读写器。保存采用同目录临时文件，避免应用崩溃留下半个 JSON。
class ProjectFileStore {
  const ProjectFileStore();

  Future<void> save(String path, VsasrProject project) async {
    final File target = File(path);
    final File temporary = File('$path.tmp');
    ensureValidSubtitleTimeline(
      project.result.segments,
      duration: project.result.duration,
    );
    final String content = const JsonEncoder.withIndent('  ')
        .convert(project.toJson());
    await temporary.writeAsString('$content\n', flush: true);
    await temporary.rename(target.path);
  }

  Future<VsasrProject> load(String path) async {
    final String content = await File(path).readAsString();
    return _decode(content);
  }

  /// 从文件选择器或 SAF 读取的字节解析项目，不要求底层存在本地路径。
  VsasrProject loadBytes(Uint8List bytes) => _decode(utf8.decode(bytes));

  /// 在应用支持目录写入一份稳定副本，供 Android 最近项目跨进程重启恢复。
  /// [identity] 只用于生成文件名，不会写入项目内容。
  Future<String> cacheForRecentProject(
    VsasrProject project, {
    required String identity,
  }) async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory directory = Directory(
      p.join(support.path, 'recent_projects'),
    );
    await directory.create(recursive: true);
    final String digest = sha256
        .convert(utf8.encode(identity))
        .toString()
        .substring(0, 32);
    final String path = p.join(directory.path, '$digest.vsasr.json');
    await save(path, project);
    return path;
  }

  VsasrProject _decode(String content) {
    try {
      return VsasrProject.fromJson(jsonDecode(content));
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('项目文件 JSON 无法解析：$error');
    }
  }
}
