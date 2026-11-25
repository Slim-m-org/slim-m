// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ends a share whose broadcast extension died without saying so.
library;

import 'dart:async';

/// While a broadcast runs, polls how long the extension has been silent and
/// declares it dead once the silence outlasts [tolerance].
class BroadcastHeartbeatWatch {
  BroadcastHeartbeatWatch({
    required this.silence,
    required this.onLost,
    this.pollEvery = const Duration(seconds: 3),
    this.tolerance = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Time since the extension last beat, or null if it never has.
  final Future<Duration?> Function() silence;
  final void Function() onLost;
  final Duration pollEvery;
  final Duration tolerance;
  final DateTime Function() _clock;

  Timer? _timer;
  DateTime? _startedAt;
  DateTime? _lastPollAt;
  bool _polling = false;

  void broadcastChanged({required bool broadcasting}) {
    _timer?.cancel();
    _timer = null;
    if (!broadcasting) return;
    _startedAt = _clock();
    _lastPollAt = _startedAt;
    _timer = Timer.periodic(pollEvery, (_) => unawaited(poll()));
  }

  Future<void> poll() async {
    final startedAt = _startedAt;
    if (_timer == null || startedAt == null || _polling) return;
    _polling = true;
    try {
      // After a suspension the beats queued meanwhile are not delivered yet, so this poll proves nothing.
      final polledAt = _clock();
      final stalled = polledAt.difference(_lastPollAt ?? startedAt) > tolerance;
      _lastPollAt = polledAt;
      if (stalled) return;
      final reported = await silence();
      final sinceStart = _clock().difference(startedAt);
      // A beat older than this broadcast belongs to a previous one.
      final quiet =
          reported == null || reported > sinceStart ? sinceStart : reported;
      if (_timer != null && quiet > tolerance) {
        _timer?.cancel();
        _timer = null;
        onLost();
      }
    } finally {
      _polling = false;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
