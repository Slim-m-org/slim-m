// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The arithmetic coordinate length must equal what `jsonEncode` emits.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/stroke_splitter.dart';

void main() {
  test('arithmetic length equals the jsonEncode length', () {
    final random = math.Random(13);
    final samples = <double>[
      0,
      -0.0,
      0.001,
      -0.001,
      0.005,
      0.01,
      -0.01,
      0.1,
      1,
      9.99,
      10,
      99.995,
      100,
      1000,
      9999.99,
      -9999.99,
      10000,
      20000.5,
      -20000.25,
      0.07,
      5.5,
    ];
    for (var i = 0; i < 20000; i++) {
      final scale = math.pow(10, random.nextInt(6)).toDouble();
      samples.add((random.nextDouble() * 2 - 1) * scale);
    }
    for (final v in samples) {
      expect(debugNumLen(v), debugJsonNumLen(v), reason: 'value $v');
    }
  });
}
