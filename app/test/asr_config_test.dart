import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/asr/asr_config.dart';

void main() {
  test('输入增益旧配置默认0，序列化和复制保留增益', () {
    expect(AsrConfig.fromJson(<String, dynamic>{}).inputGainDb, 0);
    final AsrConfig config = AsrConfig(inputGainDb: 6);
    expect(AsrConfig.fromJson(config.toJson()).inputGainDb, 6);
    expect(config.copyWith(language: 'en').inputGainDb, 6);
    expect(config.copyWith(inputGainDb: 12).inputGainDb, 12);
    expect(config.copyWith(inputGainDb: 0).inputGainDb, 0);
  });

  test('输入增益在运行时拒绝非有限数字和越界值', () {
    for (final double value in <double>[
      -0.1,
      12.1,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(() => AsrConfig(inputGainDb: value), throwsArgumentError);
      expect(
        () => AsrConfig.fromJson(<String, dynamic>{'input_gain_db': value}),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
    }
  });
}
