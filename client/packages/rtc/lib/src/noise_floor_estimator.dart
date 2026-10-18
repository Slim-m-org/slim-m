// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picks the input gate threshold from the live level readings, for the
/// "Automatic" sensitivity; see docs/voice-input-gate.md.
library;

import 'dart:math' as math;

import 'input_gate.dart';

/// Readings at or below this are a muted or silent device, not a room.
const double _kSilenceDb = kInputFloorDb + 1;

/// Tracks the room's noise floor as a low percentile of recent levels, so
/// speech (the loud minority) never raises it, and holds the threshold a
/// fixed margin above it.
class NoiseFloorEstimator {
  NoiseFloorEstimator({
    this.initialThresholdDb = kDefaultInputThresholdDb,
    this.windowSamples = 240,
    this.warmupSamples = 60,
    this.percentile = 0.2,
    this.marginDb = 12,
    this.minThresholdDb = -60,
    this.maxThresholdDb = -38,
    this.riseDbPerSample = 0.15,
    this.fallDbPerSample = 0.05,
  }) : _thresholdDb = initialThresholdDb;

  /// Where the threshold sits until [warmupSamples] readings have arrived.
  final double initialThresholdDb;

  /// How many readings the percentile looks over; 240 is 12 s at 50 ms.
  final int windowSamples;
  final int warmupSamples;

  /// Which share of the window counts as noise rather than speech.
  final double percentile;

  /// How far above the floor the threshold sits.
  final double marginDb;

  /// Never opens on near-silence or swallows quiet speech.
  final double minThresholdDb;
  final double maxThresholdDb;

  /// Per-reading step limits: it rises faster than it falls, so a fan
  /// starting is caught sooner than a room going quiet is trusted.
  final double riseDbPerSample;
  final double fallDbPerSample;

  final _window = <({double levelDb, int weight})>[];
  int _weight = 0;
  double _thresholdDb;

  double get thresholdDb => _thresholdDb;

  /// The current noise floor, or null before the warm-up is over.
  double? get floorDb => _weight < warmupSamples ? null : _floor();

  /// Feeds one reading covering [interval] and returns the threshold to use
  /// now. The window and the step limits count 50 ms samples, so a slower
  /// poll counts for as many as it spans.
  double add(
    double levelDb, {
    Duration interval = kInputGateDisplayInterval,
  }) {
    if (levelDb <= _kSilenceDb) return _thresholdDb;
    final weight = math.max(
      1,
      interval.inMicroseconds ~/ kInputGateDisplayInterval.inMicroseconds,
    );
    _window.add((levelDb: levelDb, weight: weight));
    _weight += weight;
    while (_weight > windowSamples && _window.length > 1) {
      _weight -= _window.removeAt(0).weight;
    }
    if (_weight < warmupSamples) return _thresholdDb;
    final target = (_floor() + marginDb).clamp(minThresholdDb, maxThresholdDb);
    final step =
        (target > _thresholdDb ? riseDbPerSample : fallDbPerSample) * weight;
    final delta = (target - _thresholdDb).clamp(-step, step);
    _thresholdDb += delta;
    return _thresholdDb;
  }

  /// Forgets the window and restarts from [thresholdDb].
  void reset(double thresholdDb) {
    _window.clear();
    _weight = 0;
    _thresholdDb = thresholdDb;
  }

  double _floor() {
    final sorted = [..._window]..sort((a, b) => a.levelDb.compareTo(b.levelDb));
    final target = (_weight - 1) * percentile;
    var seen = 0;
    for (final entry in sorted) {
      seen += entry.weight;
      if (seen > target) return entry.levelDb;
    }
    return sorted.last.levelDb;
  }
}
