/// 翻译层的服务商无关契约，以及识别结果的译文映射。
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:vsasr_app/src/asr/segment.dart';

/// 翻译进度回调：已完成的文本数 / 总文本数。
typedef TranslationProgress = void Function(int done, int total);

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
  int maxRetries = 2,
  Duration retryDelay = const Duration(milliseconds: 250),
  Duration requestTimeout = const Duration(seconds: 30),
  TranslationProgress? onProgress,
  TranslationCancellation? isCancelled,
}) async {
  final String target = to.trim();
  if (target.isEmpty) {
    throw ArgumentError.value(to, 'to', '目标语言不能为空');
  }
  if (batchSize < 1) {
    throw ArgumentError.value(batchSize, 'batchSize', '必须 >= 1');
  }
  final TranslationRequestPolicy policy = TranslationRequestPolicy(
    maxRetries: maxRetries,
    requestTimeout: requestTimeout,
    initialRetryDelay: retryDelay,
  );
  policy.validate();

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
    final List<String> translatedBatch = await translateTexts(
      provider,
      batch,
      from: from,
      to: target,
      policy: policy,
      isCancelled: isCancelled,
    );
    translated.addAll(translatedBatch);
    onProgress?.call(translated.length, texts.length);
  }

  final List<Segment> segments = List<Segment>.of(result.segments);
  for (int index = 0; index < positions.length; index++) {
    final int position = positions[index];
    segments[position] = segments[position].copyWith(
      translation: translated[index].trim(),
    );
  }
  return result.copyWith(segments: segments);
}
