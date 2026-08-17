import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';
import 'package:vsasr_app/src/asr/segment.dart';
import 'package:vsasr_app/src/project/project_file.dart';

void main() {
  test('项目文件 round-trip 保留配置、媒体引用、时间轴和译文', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'vsasr_project_test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final String path = '${directory.path}/demo.vsasr.json';
    final VsasrProject project = VsasrProject(
      mediaPath: '/Users/me/video.mp4',
      config: AsrConfig(
        language: 'yue',
        useItn: false,
        numThreads: 4,
        partialInterval: 0.8,
        vad: VadConfig(
          threshold: 0.6,
          minSilenceDuration: 0.4,
          minSpeechDuration: 0.2,
          maxSpeechDuration: 18.0,
          windowSize: 512,
        ),
      ),
      result: TranscriptionResult(
        language: 'yue',
        duration: 2.0,
        segments: <Segment>[
          Segment(
            text: '原文',
            start: 0.0,
            end: 1.0,
            language: 'yue',
            index: 0,
            translation: '译文',
            words: <Word>[Word(text: '原', start: 0.0, end: 0.5)],
          ),
          Segment(text: '第二句', start: 1.0, end: 2.0, index: 1),
        ],
      ),
    );

    const ProjectFileStore store = ProjectFileStore();
    await store.save(path, project);
    final VsasrProject loaded = await store.load(path);
    final VsasrProject loadedFromBytes = store.loadBytes(
      await File(path).readAsBytes(),
    );

    expect(loaded.mediaPath, project.mediaPath);
    expect(loaded.config.language, 'yue');
    expect(loaded.config.vad.threshold, 0.6);
    expect(loaded.result.segments.first.text, '原文');
    expect(loaded.result.segments.first.translation, '译文');
    expect(loaded.result.segments.first.words.single.text, '原');
    expect(loadedFromBytes.result.segments.first.translation, '译文');
    expect(await File(path).readAsString(), contains('voicesmallasr.project'));
  });

  test('项目文件拒绝错误 schema、版本和重叠时间轴', () {
    Map<String, dynamic> base() => <String, dynamic>{
      'schema': kProjectSchema,
      'version': kProjectVersion,
      'media_path': null,
      'config': AsrConfig().toJson(),
      'result': TranscriptionResult(
        duration: 2.0,
        segments: <Segment>[
          const Segment(text: 'a', start: 0.0, end: 1.2, index: 0),
          const Segment(text: 'b', start: 1.0, end: 2.0, index: 1),
        ],
      ).toJson(),
    };

    expect(
      () => VsasrProject.fromJson(<String, dynamic>{
        ...base(),
        'schema': 'other',
      }),
      throwsFormatException,
    );
    expect(
      () => VsasrProject.fromJson(<String, dynamic>{...base(), 'version': 2}),
      throwsFormatException,
    );
    expect(() => VsasrProject.fromJson(base()), throwsArgumentError);
  });

  test('自动保存可以重复覆盖并清理恢复快照', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'vsasr_autosave_test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final VsasrProject project = VsasrProject(
      mediaPath: '/tmp/audio.wav',
      config: AsrConfig(),
      result: const TranscriptionResult(
        duration: 1,
        segments: <Segment>[Segment(text: '第一次', start: 0, end: 1)],
      ),
    );
    final FileProjectAutosaveStore store = FileProjectAutosaveStore(
      rootDirectory: directory,
    );

    expect(await store.wasPreviousSessionUnclean(), isFalse);
    await store.beginSession();
    expect(await store.wasPreviousSessionUnclean(), isTrue);
    await store.save(project);
    expect((await store.load())?.result.segments.single.text, '第一次');
    await store.save(
      VsasrProject(
        mediaPath: project.mediaPath,
        config: project.config,
        result: const TranscriptionResult(
          duration: 1,
          segments: <Segment>[Segment(text: '第二次', start: 0, end: 1)],
        ),
      ),
    );
    expect((await store.load())?.result.segments.single.text, '第二次');

    await store.clear();
    expect(await store.load(), isNull);
    await store.endSession();
    expect(await store.wasPreviousSessionUnclean(), isFalse);
  });
}
