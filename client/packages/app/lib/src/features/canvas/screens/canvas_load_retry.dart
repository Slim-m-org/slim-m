// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The backoff a failed canvas read retries on: 2 s doubling to 30 s.
library;

import 'dart:async';

class CanvasLoadRetry {
  Timer? _timer;
  int _attempts = 0;

  /// Runs [retry] after the next backoff step.
  void schedule(void Function() retry) {
    _timer?.cancel();
    final seconds = (2 << _attempts).clamp(2, 30);
    _attempts++;
    _timer = Timer(Duration(seconds: seconds), retry);
  }

  /// A read went through: the next failure starts from the shortest wait.
  void succeeded() {
    _timer?.cancel();
    _attempts = 0;
  }

  void cancel() => _timer?.cancel();
}
