// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How fast the dock's level bar falls, in dB per second.
const double kMicLevelReleaseDbPerSecond = 125;

/// Instant attack, steady release, so the per-poll peaks from the native
/// gate read as a smooth bar. Release is timed by the clock, not by polls.
class MicLevelBallistics {
  MicLevelBallistics(this._now);

  final DateTime Function() _now;
  double? _levelDb;
  DateTime? _at;

  double step(double rawDb) {
    final now = _now();
    final at = _at;
    final held = _levelDb;
    _at = now;
    if (at == null || held == null) return _levelDb = rawDb;
    final seconds = now.difference(at).inMicroseconds / 1e6;
    final fallen = held - kMicLevelReleaseDbPerSecond * seconds;
    return _levelDb = rawDb > fallen ? rawDb : fallen;
  }
}

/// Overridden in tests to drive the release by hand.
final micLevelClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

final micLevelBallisticsProvider = Provider.autoDispose<MicLevelBallistics>(
  (ref) => MicLevelBallistics(ref.watch(micLevelClockProvider)),
);
