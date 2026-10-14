// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [NoiseFloorEstimator] on synthetic 50 ms level sequences.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/noise_floor_estimator.dart';

/// Seconds to samples at the monitor's 50 ms poll.
int _s(int seconds) => seconds * 20;

class _Feed {
  _Feed(this.estimator);

  final NoiseFloorEstimator estimator;
  final _random = math.Random(7);

  /// Noise around [centerDb] with +/- 1.5 dB of jitter.
  void noise(double centerDb, int samples) {
    for (var i = 0; i < samples; i++) {
      estimator.add(centerDb + (_random.nextDouble() - 0.5) * 3);
    }
  }

  /// Quiet room with a loud burst for [burst] of every [period] samples.
  void talk(double floorDb, double speechDb, int samples,
      {int period = 40, int burst = 20}) {
    for (var i = 0; i < samples; i++) {
      final speaking = i % period < burst;
      estimator.add(
        (speaking ? speechDb : floorDb) + (_random.nextDouble() - 0.5) * 3,
      );
    }
  }
}

void main() {
  test('stays at the starting value until the warm-up is over', () {
    final estimator = NoiseFloorEstimator(initialThresholdDb: -50);
    _Feed(estimator).noise(-70, 59);
    expect(estimator.thresholdDb, -50);
    expect(estimator.floorDb, isNull);
  });

  test('steady noise settles a fixed margin above the floor', () {
    final estimator = NoiseFloorEstimator(initialThresholdDb: -50);
    _Feed(estimator).noise(-55, _s(60));
    expect(estimator.floorDb, closeTo(-56, 1.5));
    expect(estimator.thresholdDb, closeTo(-44, 2));
  });

  test('speech bursts do not drag the floor up', () {
    final estimator = NoiseFloorEstimator(initialThresholdDb: -50);
    _Feed(estimator).talk(-58, -25, _s(90));
    expect(estimator.floorDb, closeTo(-59, 1.5));
    expect(estimator.thresholdDb, closeTo(-46, 2));
    expect(estimator.thresholdDb, lessThan(-30));
  });

  test('a noise step up is followed, slowly', () {
    final estimator = NoiseFloorEstimator(initialThresholdDb: -50);
    final feed = _Feed(estimator)..noise(-62, _s(40));
    final before = estimator.thresholdDb;
    feed.noise(-48, _s(5));
    expect(estimator.thresholdDb - before, lessThan(0.15 * _s(5) + 0.01));
    feed.noise(-48, _s(60));
    expect(estimator.thresholdDb, closeTo(-36, 2.5));
  });

  test('a noise step down is followed more slowly than a step up', () {
    final up = NoiseFloorEstimator(initialThresholdDb: -50);
    final down = NoiseFloorEstimator(initialThresholdDb: -50);
    _Feed(up).noise(-62, _s(60));
    _Feed(down).noise(-45, _s(60));
    final upStart = up.thresholdDb;
    final downStart = down.thresholdDb;
    _Feed(up).noise(-45, _s(14));
    _Feed(down).noise(-62, _s(14));
    expect(
      up.thresholdDb - upStart,
      greaterThan(downStart - down.thresholdDb),
    );
    _Feed(down).noise(-62, _s(120));
    expect(down.thresholdDb, closeTo(-50, 2));
  });

  test('silence never pulls the threshold down to open on nothing', () {
    final estimator = NoiseFloorEstimator(initialThresholdDb: -50);
    final feed = _Feed(estimator)..noise(-55, _s(40));
    final settled = estimator.thresholdDb;
    for (var i = 0; i < _s(60); i++) {
      estimator.add(-80);
    }
    expect(estimator.thresholdDb, settled);
    feed.noise(-55, 1);
  });

  test('a very quiet room is clamped so hiss cannot open the gate', () {
    final estimator = NoiseFloorEstimator(initialThresholdDb: -50);
    _Feed(estimator).noise(-75, _s(120));
    expect(estimator.thresholdDb, -60);
  });

  test('a very loud room is clamped so quiet speech still gets through', () {
    final estimator = NoiseFloorEstimator(initialThresholdDb: -50);
    _Feed(estimator).noise(-25, _s(120));
    expect(estimator.thresholdDb, -38);
  });

  test('reset restarts from the given threshold', () {
    final estimator = NoiseFloorEstimator(initialThresholdDb: -50);
    _Feed(estimator).noise(-40, _s(60));
    estimator.reset(-45);
    expect(estimator.thresholdDb, -45);
    expect(estimator.floorDb, isNull);
  });
}
