// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one doubling-delay policy behind every client retry loop.
library;

import 'dart:math';

/// A delay that doubles from [base] to [cap], optionally spread by jitter so
/// clients that failed together do not come back together.
///
/// A value, not a timer: the caller owns the attempt count and the clock.
/// The wait a server names itself (`Retry-After`) stays with the caller and
/// only falls back to this when the response named none.
class Backoff {
  const Backoff({
    required this.base,
    required this.cap,
    this.jitter = Duration.zero,
    this.jitterFraction = 0,
  });

  final Duration base;
  final Duration cap;

  /// Up to this much is added, drawn uniformly; zero adds nothing.
  final Duration jitter;

  /// The delay is stretched by a draw in `[0, jitterFraction)` of itself.
  final double jitterFraction;

  /// The wait before retry number [attempt], counted from zero.
  Duration delay(int attempt, {Random? random}) {
    final doubled = base * (1 << min(attempt, 20));
    var wait = doubled > cap ? cap : doubled;
    if (jitterFraction > 0) {
      final draw = (random ?? Random()).nextDouble();
      wait = Duration(
        microseconds: (wait.inMicroseconds * (1 + draw * jitterFraction))
            .round(),
      );
    }
    if (jitter > Duration.zero) {
      final draw = (random ?? Random()).nextInt(jitter.inMilliseconds);
      wait += Duration(milliseconds: draw);
    }
    return wait;
  }
}
