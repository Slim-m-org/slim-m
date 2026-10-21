// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The backoff a failed canvas read retries on: 2 s doubling to 30 s.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

class CanvasLoadRetry {
  CanvasLoadRetry({math.Random? random}) : _random = random ?? math.Random();

  final math.Random _random;
  Timer? _timer;
  int _attempts = 0;

  /// How long the next failure waits: a doubling from two seconds, held at
  /// the ceiling, with a fifth of jitter so clients that failed together do
  /// not return together.
  @visibleForTesting
  Duration nextDelay() {
    final seconds = math.min(2 << math.min(_attempts, 5), 30);
    final jitter = 1 + (_random.nextDouble() * 0.2);
    return Duration(milliseconds: (seconds * 1000 * jitter).round());
  }

  /// Runs [retry] after the next backoff step.
  void schedule(void Function() retry) {
    _timer?.cancel();
    final delay = nextDelay();
    _attempts++;
    _timer = Timer(delay, retry);
  }

  /// A read went through: the next failure starts from the shortest wait.
  void succeeded() {
    _timer?.cancel();
    _attempts = 0;
  }

  void cancel() => _timer?.cancel();
}
