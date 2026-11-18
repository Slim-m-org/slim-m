// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Notices a socket that stopped answering without ever closing.
library;

import 'dart:async';

/// Pings on a fixed beat and gives up once the peer stays silent.
///
/// A proxy or NAT that drops its upstream side leaves the client's end open
/// and mute, so the connection never reports a close and the layer above
/// never reconnects: the account reads offline to everyone and misses every
/// event until the app restarts. Counting silent beats rather than reading a
/// wall clock keeps this deterministic under fake time.
class SocketLiveness {
  SocketLiveness({
    required this.ping,
    required this.onSilent,
    this.interval = const Duration(seconds: 20),
    this.maxSilentBeats = 2,
  });

  final void Function() ping;
  final void Function() onSilent;
  final Duration interval;

  /// Consecutive beats with no inbound frame at all before [onSilent] fires.
  final int maxSilentBeats;

  Timer? _timer;
  bool _heard = true;
  int _silentBeats = 0;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => _beat());
  }

  Completer<void>? _awaiting;

  /// Any inbound frame counts, not only a pong.
  void heard() {
    _heard = true;
    final waiting = _awaiting;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  /// Pings now and says whether anything came back within [timeout].
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) async {
    final waiting = _awaiting ??= Completer<void>();
    ping();
    try {
      await waiting.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      if (identical(_awaiting, waiting)) _awaiting = null;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _beat() {
    if (_heard) {
      _silentBeats = 0;
    } else if (++_silentBeats >= maxSilentBeats) {
      stop();
      onSilent();
      return;
    }
    _heard = false;
    ping();
  }
}
