/// 翻译层的服务商无关契约，以及识别结果的译文映射。
library;

import 'package:vsasr_app/src/asr/segment.dart';

/// 翻译进度回调：已完成的文本数 / 总文本数。
typedef TranslationProgress = void Function(int done, int total);

/// 在线或离线翻译服务商的最小契约。
///
/// [texts] 与返回值必须一一对应且顺序一致。服务商的 HTTP 协议、认证方式
/// 和重试策略留在实现类里，界面和字幕层只依赖这个接口。
abstract interface class TranslationProvider {
  Future<List<String>> translate(
    List<String> texts, {
    String? from,
    required String to,
  });
}

/// 把一批字幕文本交给 [provider] 翻译，并将译文写回对应的识别段。
///
/// 空文本段不会发送给服务商，但会原样保留在结果中。服务商必须返回与
/// 非空输入等长的列表，否则说明响应无法安全映射，直接抛错而不返回部分结果。
Future<TranscriptionResult> translateResult(
  TranscriptionResult result,
  TranslationProvider provider, {
  required String to,
  int batchSize = 20,
  int maxRetries = 2,
  Duration retryDelay = const Duration(milliseconds: 250),
  TranslationProgress? onProgress,
}) async {
  final String target = to.trim();
  if (target.isEmpty) {
    throw ArgumentError.value(to, 'to', '目标语言不能为空');
  }
  if (batchSize < 1) {
    throw ArgumentError.value(batchSize, 'batchSize', '必须 >= 1');
  }
  if (maxRetries < 0) {
    throw ArgumentError.value(maxRetries, 'maxRetries', '不能为负');
  }
  if (retryDelay.isNegative) {
    throw ArgumentError.value(retryDelay, 'retryDelay', '不能为负');
  }

  final List<int> positions = <int>[];
  final List<String> texts = <String>[];
  for (int index = 0; index < result.segments.length; index++) {
    final String text = result.segments[index].text.trim();
    if (text.isEmpty) continue;
    positions.add(index);
    texts.add(text);
  }
  if (texts.isEmpty) {
    onProgress?.call(0, 0);
    return result;
  }

  final String source = result.language.trim();
  final String? from = source.isEmpty || source == 'auto' ? null : source;
  final List<String> translated = <String>[];
  onProgress?.call(0, texts.length);
  for (int start = 0; start < texts.length; start += batchSize) {
    final int end = (start + batchSize).clamp(0, texts.length);
    final List<String> batch = texts.sublist(start, end);
    final List<String> translatedBatch = await _translateBatch(
      provider,
      batch,
      from: from,
      to: target,
      maxRetries: maxRetries,
      retryDelay: retryDelay,
    );
    translated.addAll(translatedBatch);
    onProgress?.call(translated.length, texts.length);
  }

  final List<Segment> segments = List<Segment>.of(result.segments);
  for (int index = 0; index < positions.length; index++) {
    final int position = positions[index];
    segments[position] = segments[position].copyWith(translation: translated[index].trim());
  }
  return result.copyWith(segments: segments);
}

Future<List<String>> _translateBatch(
  TranslationProvider provider,
  List<String> texts, {
  required String? from,
  required String to,
  required int maxRetries,
  required Duration retryDelay,
}) async {
  Object? lastError;
  StackTrace? lastStack;
  for (int attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      final List<String> translated = await provider.translate(texts, from: from, to: to);
      if (translated.length != texts.length) {
        throw StateError(
          '翻译服务返回 ${translated.length} 条结果，需要 ${texts.length} 条，无法安全对应字幕',
        );
      }
      return translated;
    } on Object catch (error, stack) {
      lastError = error;
      lastStack = stack;
      if (attempt == maxRetries) break;
      if (retryDelay > Duration.zero) await Future<void>.delayed(retryDelay);
    }
  }
  Error.throwWithStackTrace(lastError!, lastStack!);
}
