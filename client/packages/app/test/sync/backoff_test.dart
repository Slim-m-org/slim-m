// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/backoff.dart';

class _Fixed implements Random {
  _Fixed({this.intDraw = 0, this.doubleDraw = 0});
  final int intDraw;
  final double doubleDraw;
  @override
  int nextInt(int max) => intDraw;
  @override
  double nextDouble() => doubleDraw;
  @override
  bool nextBool() => false;
}

void main() {
  const plain = Backoff(base: Duration(seconds: 1), cap: Duration(seconds: 8));

  test('doubles from the base and holds at the cap', () {
    expect(
      [for (var i = 0; i < 6; i++) plain.delay(i).inSeconds],
      [1, 2, 4, 8, 8, 8],
    );
  });

  test('a huge attempt count does not overflow', () {
    expect(plain.delay(100000), const Duration(seconds: 8));
  });

  test('additive jitter is drawn below its bound and added on top', () {
    const jittered = Backoff(
      base: Duration(seconds: 1),
      cap: Duration(seconds: 8),
      jitter: Duration(seconds: 1),
    );
    expect(
      jittered.delay(1, random: _Fixed(intDraw: 999)),
      const Duration(milliseconds: 2999),
    );
    expect(jittered.delay(1, random: _Fixed()), const Duration(seconds: 2));
  });

  test('fractional jitter stretches the capped delay', () {
    const stretched = Backoff(
      base: Duration(seconds: 2),
      cap: Duration(seconds: 30),
      jitterFraction: 0.2,
    );
    expect(
      stretched.delay(10, random: _Fixed(doubleDraw: 0.5)),
      const Duration(seconds: 33),
    );
  });
}
