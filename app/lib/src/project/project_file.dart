/// VoiceSmallASR 项目文件：媒体路径引用、识别配置和当前字幕快照。
library;

import 'dart:convert';
import 'dart:io';

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
    try {
      return VsasrProject.fromJson(jsonDecode(content));
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('项目文件 JSON 无法解析：$error');
    }
  }
}
