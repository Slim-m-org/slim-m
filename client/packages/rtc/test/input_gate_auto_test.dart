// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/input_gate_auto.dart';

/// Feeds [count] readings produced by [level] and answers the last threshold.
double? _run(AutoInputThreshold auto, int count, double Function(int i) level) {
  for (var i = 0; i < count; i++) {
    auto.add(level(i));
  }
  return auto.threshold;
}

void main() {
  test('a steady room puts the threshold a margin above its noise', () {
    final auto = AutoInputThreshold();
    final t = _run(auto, 400, (i) => -60 + (i % 3) - 1);
    expect(t, closeTo(-48, 1.5));
  });

  test('speech bursts do not drag the threshold up', () {
    final auto = AutoInputThreshold();
    _run(auto, 300, (_) => -60);
    final quiet = auto.threshold!;
    // Talking a third of the time, loud.
    final t = _run(auto, 300, (i) => i % 3 == 0 ? -20 : -60);
    expect(t, closeTo(quiet, 0.5));
  });

  test('a noisier room raises it slowly, a quieter one lowers it slowly', () {
    final auto = AutoInputThreshold();
    _run(auto, 300, (_) => -60);
    expect(auto.threshold, closeTo(-48, 0.5));
    // A fan comes on: one update later it has moved only one step.
    _run(auto, 300, (_) => -45);
    expect(auto.threshold, lessThanOrEqualTo(-33));
    _run(auto, 600, (_) => -45);
    expect(auto.threshold, closeTo(-33, 0.5));
    _run(auto, 900, (_) => -60);
    expect(auto.threshold, closeTo(-48, 0.5));
  });

  test('silence never pulls it below the floor that would open on hiss', () {
    final auto = AutoInputThreshold();
    expect(_run(auto, 400, (_) => -90), -65);
  });

  test('a loud room never pushes it past where quiet speech is lost', () {
    final auto = AutoInputThreshold();
    expect(_run(auto, 2000, (_) => -25), -30);
  });

  test('nothing is decided before enough has been heard', () {
    final auto = AutoInputThreshold();
    expect(_run(auto, 30, (_) => -60), isNull);
  });
}
