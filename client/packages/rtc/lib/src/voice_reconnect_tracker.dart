// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether LiveKit is repairing the call's transport, and how often it had to.
///
/// Display and logging only: nothing here repairs a connection or rejoins.
/// The SDK's own resume and full restart run unchanged; this watches them.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// How long the SDK may stay silent before a reconnect is treated as stuck.
///
/// Every retry attempt emits an event, so this only fires when the SDK never
/// reports that it finished, which would otherwise leave the call held forever.
const Duration kReconnectQuiet = Duration(seconds: 30);

/// How the SDK is repairing the connection.
enum ReconnectKind {
  /// The signal socket dropped and the media path is being kept.
  resume,

  /// The peer connections were reset and media is interrupted.
  restart,
}

/// What a call's transport blips added up to, for the end-of-call summary.
class ReconnectStats {
  const ReconnectStats({
    this.count = 0,
    this.total = Duration.zero,
    this.longest = Duration.zero,
  });

  static const none = ReconnectStats();

  final int count;
  final Duration total;
  final Duration longest;

  /// The summary line, or null when the transport never blipped.
  String? get line => count == 0
      ? null
      : '[voice-health] call summary transport blips=$count '
          'total=${total.inMilliseconds}ms '
          'longest=${longest.inMilliseconds}ms';
}

class ReconnectTracker {
  ReconnectTracker({
    this.log,
    DateTime Function()? clock,
    this.quiet = kReconnectQuiet,
  }) : _clock = clock ?? DateTime.now;

  /// Where each transition is written; set by the session that owns the call.
  void Function(String line)? log;

  final DateTime Function() _clock;
  final Duration quiet;

  /// True from the SDK reporting a reconnect until it reports the end of it.
  final ValueNotifier<bool> active = ValueNotifier(false);

  bool _disposed = false;
  DateTime? _since;
  Timer? _stuck;
  int _count = 0;
  Duration _total = Duration.zero;
  Duration _longest = Duration.zero;

  ReconnectStats get stats =>
      ReconnectStats(count: _count, total: _total, longest: _longest);

  /// The SDK began, or escalated, a reconnect.
  void started(ReconnectKind kind) {
    if (_disposed) return;
    final wasActive = active.value;
    _since ??= _clock();
    _arm();
    log?.call(
      wasActive
          ? 'Call transport: still reconnecting, now a ${kind.name} '
              '(${_elapsedMs()} ms in)'
          : 'Call transport: reconnecting (${kind.name})',
    );
    active.value = true;
  }

  /// The SDK is retrying; also marks a reconnect whose start was not seen.
  void attempted(int attempt, int maxAttempts, int nextDelayMs) {
    if (_disposed) return;
    final wasActive = active.value;
    _since ??= _clock();
    _arm();
    log?.call(
      'Call transport: attempt $attempt of $maxAttempts '
      '(${_elapsedMs()} ms in, next retry in $nextDelayMs ms)',
    );
    if (!wasActive) active.value = true;
  }

  /// The reconnect is over, repaired or not; [cause] says which for the log.
  void ended(String cause) {
    if (_disposed) return;
    _stuck?.cancel();
    _stuck = null;
    final since = _since;
    _since = null;
    if (!active.value || since == null) return;
    final elapsed = _clock().difference(since);
    _count++;
    _total += elapsed;
    if (elapsed > _longest) _longest = elapsed;
    log?.call('Call transport: $cause after ${elapsed.inMilliseconds} ms');
    active.value = false;
  }

  /// Forgets the counts, at the end of a call; an episode in flight stays.
  void resetStats() {
    _count = 0;
    _total = Duration.zero;
    _longest = Duration.zero;
  }

  void dispose() {
    _disposed = true;
    _stuck?.cancel();
    active.dispose();
  }

  int _elapsedMs() => _clock().difference(_since ?? _clock()).inMilliseconds;

  void _arm() {
    _stuck?.cancel();
    _stuck = Timer(
        quiet, () => ended('no reconnect event for ${quiet.inSeconds} s'));
  }
}
