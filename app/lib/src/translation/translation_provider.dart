/// 翻译层的服务商无关契约，以及识别结果的译文映射。
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:vsasr_app/src/asr/segment.dart';

/// 翻译进度回调：已完成的文本数 / 总文本数。
typedef TranslationProgress = void Function(int done, int total);

/// 每完成一个翻译批次，就把当前可用的部分译文交给界面显示。
typedef TranslationResultProgress = void Function(
  TranscriptionResult result,
  int done,
  int total,
);

/// 翻译请求是否已由调用方取消。
typedef TranslationCancellation = bool Function();

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

/// 可由调用方主动释放网络资源的 provider。
abstract interface class ClosableTranslationProvider
    implements TranslationProvider {
  void close();
}

/// 翻译服务请求或响应无效时抛出的错误。
class TranslationException implements Exception {
  const TranslationException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'TranslationException: $message';
}

/// 翻译请求在等待或返回后被调用方取消。
///
/// 该异常不是服务商故障；实时/视频任务收到它时不应把已关闭的翻译开关显示为失败。
class TranslationCancelledException implements Exception {
  const TranslationCancelledException();

  @override
  String toString() => 'TranslationCancelledException';
}

/// 文件、批量、实时和视频字幕共用的网络翻译策略。
///
/// HTTP 429 与瞬时网络/服务端错误会指数退避；认证、地址、模型或响应格式错误会
/// 立即返回给用户，不会浪费请求额度反复重试。
class TranslationRequestPolicy {
  const TranslationRequestPolicy({
    this.maxRetries = 2,
    this.requestTimeout = const Duration(seconds: 30),
    this.initialRetryDelay = const Duration(milliseconds: 250),
  });

  final int maxRetries;
  final Duration requestTimeout;
  final Duration initialRetryDelay;

  Duration retryDelayFor(int retryNumber) {
    if (initialRetryDelay <= Duration.zero) return Duration.zero;
    final int multiplier = 1 << retryNumber.clamp(0, 6).toInt();
    return Duration(
      microseconds: initialRetryDelay.inMicroseconds * multiplier,
    );
  }

  void validate() {
    if (maxRetries < 0) {
      throw ArgumentError.value(maxRetries, 'maxRetries', '不能为负');
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout', '必须大于 0');
    }
    if (initialRetryDelay.isNegative) {
      throw ArgumentError.value(initialRetryDelay, 'initialRetryDelay', '不能为负');
    }
  }
}

/// 统一执行一批文本翻译，校验数量、超时、取消与可重试错误。
Future<List<String>> translateTexts(
  TranslationProvider provider,
  List<String> texts, {
  String? from,
  required String to,
  TranslationRequestPolicy policy = const TranslationRequestPolicy(),
  TranslationCancellation? isCancelled,
}) async {
  policy.validate();
  if (texts.isEmpty) return const <String>[];
  final String target = to.trim();
  if (target.isEmpty) {
    throw ArgumentError.value(to, 'to', '目标语言不能为空');
  }
  if (texts.any((String text) => text.trim().isEmpty)) {
    throw ArgumentError.value(texts, 'texts', '不能包含空文本');
  }

  Object? lastError;
  StackTrace? lastStack;
  for (int attempt = 0; attempt <= policy.maxRetries; attempt++) {
    if (isCancelled?.call() == true) {
      throw const TranslationCancelledException();
    }
    try {
      final List<String> translated = await provider
          .translate(texts, from: from, to: target)
          .timeout(policy.requestTimeout);
      if (isCancelled?.call() == true) {
        throw const TranslationCancelledException();
      }
      if (translated.length != texts.length) {
        throw StateError(
          '翻译服务返回 ${translated.length} 条结果，需要 ${texts.length} 条，无法安全对应字幕',
        );
      }
      return translated;
    } on TranslationCancelledException {
      rethrow;
    } on Object catch (error, stack) {
      lastError = error;
      lastStack = stack;
      if (!_isRetryableTranslationError(error) ||
          attempt == policy.maxRetries) {
        break;
      }
      final Duration delay = policy.retryDelayFor(attempt);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
    }
  }
  Error.throwWithStackTrace(lastError!, lastStack!);
}

bool _isRetryableTranslationError(Object error) {
  if (error is TimeoutException) return true;
  if (error is SocketException || error is http.ClientException) return true;
  if (error is TranslationException) {
    final int? status = error.statusCode;
    return status == 408 ||
        status == 409 ||
        status == 425 ||
        status == 429 ||
        (status != null && status >= 500 && status <= 599);
  }
  // 兼容既有 provider 对瞬时错误使用 StateError 的实现；配置错误由
  // ArgumentError/TranslationException（4xx）表示，不会走这里。
  return error is StateError && error.message.contains('临时');
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
  int? initialBatchSize,
  int maxConcurrentBatches = 1,
  int? prioritySegmentIndex,
  bool skipTranslated = false,
  int maxRetries = 2,
  Duration retryDelay = const Duration(milliseconds: 250),
  Duration requestTimeout = const Duration(seconds: 30),
  TranslationProgress? onProgress,
  TranslationResultProgress? onPartialResult,
  TranslationCancellation? isCancelled,
}) async {
  final String target = to.trim();
  if (target.isEmpty) {
    throw ArgumentError.value(to, 'to', '目标语言不能为空');
  }
  if (batchSize < 1) {
    throw ArgumentError.value(batchSize, 'batchSize', '必须 >= 1');
  }
  if (initialBatchSize != null && initialBatchSize < 1) {
    throw ArgumentError.value(initialBatchSize, 'initialBatchSize', '必须 >= 1');
  }
  if (maxConcurrentBatches < 1) {
    throw ArgumentError.value(
      maxConcurrentBatches,
      'maxConcurrentBatches',
      '必须 >= 1',
    );
  }
  final TranslationRequestPolicy policy = TranslationRequestPolicy(
    maxRetries: maxRetries,
    requestTimeout: requestTimeout,
    initialRetryDelay: retryDelay,
  );
  policy.validate();

  final List<int> availablePositions = <int>[];
  for (int index = 0; index < result.segments.length; index++) {
    final Segment segment = result.segments[index];
    final String text = segment.text.trim();
    if (text.isEmpty) continue;
    if (skipTranslated && (segment.translation ?? '').trim().isNotEmpty) {
      continue;
    }
    availablePositions.add(index);
  }
  final int priority = (prioritySegmentIndex ?? 0).clamp(
    0,
    result.segments.isEmpty ? 0 : result.segments.length - 1,
  );
  final List<int> positions = prioritySegmentIndex == null
      ? availablePositions
      : <int>[
          ...availablePositions.where((int index) => index >= priority),
          ...availablePositions.where((int index) => index < priority),
        ];
  final List<String> texts = positions
      .map((int index) => result.segments[index].text.trim())
      .toList(growable: false);
  if (texts.isEmpty) {
    onProgress?.call(0, 0);
    return result;
  }

  final String source = result.language.trim();
  final String? from = source.isEmpty || source == 'auto' ? null : source;
  final List<Segment> segments = List<Segment>.of(result.segments);
  int translatedCount = 0;
  final List<({int start, int end})> batches = <({int start, int end})>[];
  int cursor = 0;
  if (texts.isNotEmpty) {
    final int firstEnd = (initialBatchSize ?? batchSize).clamp(1, texts.length);
    batches.add((start: 0, end: firstEnd));
    cursor = firstEnd;
  }
  while (cursor < texts.length) {
    final int end = (cursor + batchSize).clamp(0, texts.length);
    batches.add((start: cursor, end: end));
    cursor = end;
  }
  int nextBatch = 0;
  Object? firstError;
  StackTrace? firstStack;
  onProgress?.call(0, texts.length);
  Future<void> translateNextBatches() async {
    while (firstError == null && nextBatch < batches.length) {
      final ({int start, int end}) range = batches[nextBatch++];
      final int start = range.start;
      final int end = range.end;
      final List<String> batch = texts.sublist(start, end);
      late final List<String> translatedBatch;
      try {
        translatedBatch = await translateTexts(
          provider,
          batch,
          from: from,
          to: target,
          policy: policy,
          isCancelled: isCancelled,
        );
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
        return;
      }
      if (firstError != null) return;
      for (int offset = 0; offset < translatedBatch.length; offset++) {
        final int position = positions[start + offset];
        segments[position] = segments[position].copyWith(
          translation: translatedBatch[offset].trim(),
        );
      }
      translatedCount += translatedBatch.length;
      final TranscriptionResult partial = result.copyWith(
        segments: List<Segment>.of(segments),
      );
      onPartialResult?.call(partial, translatedCount, texts.length);
      onProgress?.call(translatedCount, texts.length);
    }
  }

  final int workerCount = maxConcurrentBatches.clamp(1, batches.length);
  await Future.wait<void>(
    List<Future<void>>.generate(workerCount, (_) => translateNextBatches()),
  );
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStack!);
  }
  return result.copyWith(segments: segments);
}
