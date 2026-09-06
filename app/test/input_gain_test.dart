import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vsasr_app/src/audio/input_gain.dart';

void main() {
  test('默认0 dB不复制或改变音频', () {
    final Float32List input = Float32List.fromList(<double>[0, .1, -.3]);
    expect(applyInputGain(input, 0), same(input));
  });

  test('增益不修改原音频，保持静音和采样数且输出限幅', () {
    final Float32List input = Float32List.fromList(<double>[
      0,
      .1,
      -.1,
      .9,
      -.9,
    ]);
    final Float32List output = applyInputGain(input, 6);
    expect(output.length, input.length);
    expect(output[0], 0);
    expect(output[1], closeTo(.199526, 1e-6));
    expect(output[2], closeTo(-.199526, 1e-6));
    expect(output[3], 1);
    expect(output[4], -1);
    expect(input[3], closeTo(.9, 1e-6));
  });

  test('增益与音频分块边界无关', () {
    final Float32List input = Float32List.fromList(
      List<double>.generate(1000, (i) => (i % 11 - 5) / 10),
    );
    expect(<double>[
      ...applyInputGain(Float32List.sublistView(input, 0, 333), 6),
      ...applyInputGain(Float32List.sublistView(input, 333), 6),
    ], orderedEquals(applyInputGain(input, 6)));
  });
}
