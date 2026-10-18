// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Getting the microphone back when it dies under a call: a track that ended
/// or was unpublished, and a capture that reads digital silence.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show LogLevel;

import 'input_gate.dart' show kInputFloorDb;
import 'voice_log.dart';

enum MicStatus {
  /// Nothing is wrong, or the user has the mic muted.
  ok,

  /// The mic was lost and a re-enable is pending or running.
  reconnecting,

  /// Recovery gave up; a tap on the mic button or Reset microphone retries.
  unavailable,
}

class MicRecoveryTiming {
  const MicRecoveryTiming({
    this.retryBase = const Duration(milliseconds: 500),
    this.maxRetryDelay = const Duration(seconds: 8),
    this.maxRetries = 5,
    this.silence = const Duration(seconds: 10),
    this.silentCooldown = const Duration(seconds: 30),
    this.maxSilentRestarts = 3,
    this.deviceDebounce = const Duration(seconds: 1),
  });

  final Duration retryBase;
  final Duration maxRetryDelay;
  final int maxRetries;

  /// How long the level must sit at the floor before capture is restarted.
  final Duration silence;

  /// Multiplied by the restarts already made, so a truly dead source is not hammered.
  final Duration silentCooldown;
  final int maxSilentRestarts;
  final Duration deviceDebounce;
}

/// Re-enables a lost microphone with a growing delay, for as long as the user
/// still wants it open.
class MicRecovery {
  MicRecovery({
    required this.timing,
    required this.wanted,
    required this.enable,
    required this.onStatus,
    required this.log,
  });

  final MicRecoveryTiming timing;

  /// Whether the user wants the mic open and the call is up.
  final bool Function() wanted;

  /// Brings a working, unmuted track back; false or a throw means it failed.
  final Future<bool> Function() enable;
  final void Function(MicStatus status) onStatus;
  final VoiceLog log;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  int _attempts = 0;

  bool get busy => _running || _timer != null;

  /// The track went away without the user asking; retry with backoff.
  void onLost(String reason) {
    if (_disposed || !wanted() || busy) return;
    log('Microphone lost ($reason); reconnecting', level: LogLevel.warning);
    onStatus(MicStatus.reconnecting);
    _schedule();
  }

  /// Retries now with a fresh budget; true when the mic came back.
  Future<bool> recoverNow(String reason) async {
    if (_disposed || !wanted() || _running) return false;
    log('Reconnecting the microphone ($reason)');
    _timer?.cancel();
    _timer = null;
    _attempts = 0;
    onStatus(MicStatus.reconnecting);
    return _attempt();
  }

  /// A call ended or the user muted; forget any recovery in progress.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _attempts = 0;
    onStatus(MicStatus.ok);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  void _schedule() {
    final scaled = timing.retryBase * (1 << _attempts.clamp(0, 6));
    final delay = scaled > timing.maxRetryDelay ? timing.maxRetryDelay : scaled;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_attempt());
    });
  }

  Future<bool> _attempt() async {
    if (_disposed) return false;
    if (!wanted()) {
      onStatus(MicStatus.ok);
      return false;
    }
    _running = true;
    var ok = false;
    try {
      ok = await enable();
    } on Object catch (e) {
      log('Could not re-enable the microphone: $e', level: LogLevel.warning);
    } finally {
      _running = false;
    }
    if (_disposed) return ok;
    if (ok) {
      _attempts = 0;
      log('Microphone is back after reconnecting');
      onStatus(MicStatus.ok);
      return true;
    }
    _attempts++;
    if (_attempts >= timing.maxRetries) {
      log(
        'Gave up reconnecting the microphone after $_attempts attempts',
        level: LogLevel.error,
      );
      onStatus(MicStatus.unavailable);
      return false;
    }
    if (wanted()) _schedule();
    return false;
  }
}

/// Notices an unmuted mic that reads digital silence and asks for a capture
/// restart, a bounded number of times.
class SilentMicWatchdog {
  SilentMicWatchdog({
    required this.timing,
    required this.onSilent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final MicRecoveryTiming timing;
  final void Function() onSilent;
  final DateTime Function() _now;

  DateTime? _silentSince;
  DateTime? _nextAllowed;
  int _restarts = 0;

  /// [active] is false while muted, closed or out of a call.
  void observe(double levelDb, {required bool active}) {
    if (!active) return reset();
    if (levelDb > kInputFloorDb + 1) {
      _silentSince = null;
      _restarts = 0;
      return;
    }
    final now = _now();
    final since = _silentSince ??= now;
    if (now.difference(since) < timing.silence) return;
    final allowed = _nextAllowed;
    if (_restarts >= timing.maxSilentRestarts) return;
    if (allowed != null && now.isBefore(allowed)) return;
    _restarts++;
    _silentSince = null;
    _nextAllowed = now.add(timing.silentCooldown * _restarts);
    onSilent();
  }

  void reset() {
    _silentSince = null;
    _nextAllowed = null;
    _restarts = 0;
  }
}
