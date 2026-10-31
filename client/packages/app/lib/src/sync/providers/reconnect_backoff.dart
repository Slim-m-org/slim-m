// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The delay `SyncController` waits between reconnect attempts.
library;

import 'dart:async';
import 'dart:math';

import '../../backoff.dart';

/// Exponential backoff with jitter, so a server restart does not bring every
/// client back online in the same instant (a thundering herd).
///
/// Attempt N (1-indexed) waits `2^(N-1)` seconds, capped at [maxSeconds] once
/// [maxAttempt] is reached, plus a uniformly random jitter in
/// `[0, jitterMs)` milliseconds. [random] is injectable so a test can seed
/// or fake the draw; production leaves it as the real `Random()`.
/// How long a connection must stay live before the backoff forgets its failures.
const connectionStableAfter = Duration(seconds: 30);

class ReconnectBackoff {
  ReconnectBackoff({
    Random? random,
    this.maxAttempt = 6,
    this.maxSeconds = 32,
    this.jitterMs = 1000,
    this.step = const Duration(seconds: 1),
  }) : _random = random ?? Random();

  final Random _random;
  final int maxAttempt;
  final int maxSeconds;
  final int jitterMs;

  /// The length of one backoff "second"; a test shrinks it to skip real waits.
  final Duration step;
  int _attempt = 0;

  Backoff get _policy => Backoff(
    base: step,
    cap: step * maxSeconds,
    jitter: Duration(milliseconds: jitterMs),
  );

  /// The delay before the next reconnect attempt. Advances the sequence, so
  /// each call backs off further until [maxSeconds] is reached.
  Duration next() {
    _attempt = (_attempt + 1).clamp(1, maxAttempt);
    return _policy.delay(_attempt - 1, random: _random);
  }

  Timer? _stableTimer;
  bool _stable = false;

  /// Whether the current connection has stayed up long enough to trust.
  bool get stable => _stable;

  /// A connection counts as healthy only after it stays up for [stableAfter]; a
  /// reset on connect alone made a socket that drops in seconds loop at one second.
  void connected({Duration stableAfter = connectionStableAfter}) {
    _stableTimer?.cancel();
    _stableTimer = Timer(stableAfter, () {
      _stable = true;
      _attempt = 0;
    });
  }

  /// The connection went away; whatever it earned toward a reset is forfeit.
  void dropped() {
    _stableTimer?.cancel();
    _stableTimer = null;
    _stable = false;
  }

  void reset() {
    dropped();
    _attempt = 0;
  }
}
