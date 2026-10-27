// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The boost limiter leaves normal levels alone and never reaches full scale.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/soft_limit.dart';

void main() {
  test('levels under the knee pass untouched, in both polarities', () {
    for (final x in [0.0, 0.1, -0.5, 0.79, -0.8]) {
      expect(softLimit(x), x);
    }
  });

  test('a +6 dB boost of a full-scale sample stays under 1.0', () {
    expect(softLimit(2.0), lessThan(1.0));
    expect(softLimit(2.0), greaterThan(0.95));
    expect(softLimit(-2.0), greaterThan(-1.0));
  });

  test('the curve rises monotonically through the knee', () {
    var last = -2.0;
    for (var x = -4.0; x <= 4.0; x += 0.01) {
      final y = softLimit(x);
      expect(y, greaterThanOrEqualTo(last));
      last = y;
    }
  });

  test('the shaper table is symmetric and exact at silence', () {
    final curve = softLimitCurve(points: 8193, range: 2.0);
    expect(curve[4096], 0.0);
    expect(curve.first, closeTo(-curve.last, 1e-6));
    expect(curve.last, lessThanOrEqualTo(1.0));
  });

  test('only a boost goes through the limiter, a trim never does', () {
    for (final gain in [0.0, 0.5, 0.93, 0.999, 1.0]) {
      expect(limiterNeeded(gain), isFalse, reason: 'gain $gain');
    }
    expect(limiterNeeded(1.01), isTrue);
    expect(limiterNeeded(2.0), isTrue);
  });
}
