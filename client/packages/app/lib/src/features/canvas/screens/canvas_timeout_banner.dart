// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Clears the canvas's timed-out banner when the timeout lapses, because the
/// banner is what keeps drawing disabled and nothing else would end it.
library;

import 'dart:async';

import 'package:clock/clock.dart';

import 'canvas_forbidden_message.dart';

class CanvasTimeoutBanner {
  CanvasTimeoutBanner({
    required this.timedOutUntil,
    required this.error,
    required this.clear,
    DateTime Function()? now,
  }) : _now = now ?? (() => clock.now());

  /// The caller's own `Me.timedOutUntil` in Unix milliseconds, read fresh each time.
  final int? Function() timedOutUntil;
  final String? Function() error;
  final void Function() clear;
  final DateTime Function() _now;
  Timer? _timer;

  /// Call whenever the banner text or the timeout may have changed.
  void watch() {
    _timer?.cancel();
    _timer = null;
    if (!canvasErrorIsTimeout(error())) return;
    final until = timedOutUntil();
    final remaining = until == null
        ? Duration.zero
        : DateTime.fromMillisecondsSinceEpoch(until).difference(_now());
    if (remaining <= Duration.zero) return clear();
    // Re-read when it fires: a longer timeout may have replaced this one.
    _timer = Timer(remaining, watch);
  }

  void dispose() => _timer?.cancel();
}
