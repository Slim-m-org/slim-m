// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Automatic input sensitivity: the gate threshold follows the room's own
/// background noise instead of a slider. The noise floor is a low percentile
/// of the recent levels, so speech (loud, but a minority of frames) does not
/// drag it up, and the threshold sits a fixed margin above that floor,
/// moving a little at a time so a door slam or a long monologue cannot yank
/// it around.
library;

import 'dart:math' as math;

class AutoInputThreshold {
  AutoInputThreshold({
    this.windowSamples = 300,
    this.updateEvery = 20,
    this.floorPercentile = 0.2,
    this.marginDb = 12,
    this.minDb = -65,
    this.maxDb = -30,
    this.maxStepDb = 1.5,
  });

  /// Readings remembered, about 15 seconds at the gate's 50 ms poll.
  final int windowSamples;

  /// Readings between threshold updates, about one second.
  final int updateEvery;

  final double floorPercentile;
  final double marginDb;
  final double minDb;
  final double maxDb;

  /// The most the threshold moves in one update.
  final double maxStepDb;

  final List<double> _window = [];
  int _sinceUpdate = 0;
  double? _threshold;

  /// The current threshold, or null until enough has been heard.
  double? get threshold => _threshold;

  /// Feeds one level reading; answers a new threshold when it changes.
  double? add(double levelDb) {
    _window.add(levelDb);
    if (_window.length > windowSamples) _window.removeAt(0);
    if (++_sinceUpdate < updateEvery || _window.length < updateEvery * 2) {
      return null;
    }
    _sinceUpdate = 0;
    final target = (noiseFloor() + marginDb).clamp(minDb, maxDb);
    final current = _threshold;
    final next = current == null
        ? target
        : current + (target - current).clamp(-maxStepDb, maxStepDb);
    if (current != null && (next - current).abs() < 0.05) return null;
    _threshold = next;
    return next;
  }

  /// The [floorPercentile] level of the remembered window.
  double noiseFloor() {
    final sorted = [..._window]..sort();
    final index = (sorted.length * floorPercentile).floor();
    return sorted[math.min(index, sorted.length - 1)];
  }
}
