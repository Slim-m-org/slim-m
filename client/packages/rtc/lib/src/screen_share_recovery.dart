// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a running screen share from showing receivers a frozen picture: when
/// the capture goes quiet it mutes the share (their paused placeholder) and
/// restarts the capture until frames flow again.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'screen_share_liveness.dart';

class ShareRecovery {
  ShareRecovery({
    required this.read,
    required this.pause,
    required this.restart,
    this.pollEvery = const Duration(seconds: 2),
    this.retryAfter = const [
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ],
    DateTime Function()? clock,
    ShareLivenessWatch? watch,
  })  : _clock = clock ?? DateTime.now,
        _watch = watch ?? ShareLivenessWatch();

  /// The sender's stats for the running share, or null when there is none to read.
  final Future<ShareReading?> Function() read;

  /// Mutes (true) or unmutes the share's publication.
  final Future<void> Function(bool paused) pause;

  /// Stops and starts the capture again on the same source; throws when it cannot.
  final Future<void> Function() restart;

  final Duration pollEvery;
  final List<Duration> retryAfter;
  final DateTime Function() _clock;
  final ShareLivenessWatch _watch;

  Timer? _timer;
  bool _windowShare = false;
  bool _busy = false;
  bool _paused = false;
  int _attempts = 0;
  DateTime? _nextRestartAt;

  /// Whether the share is muted because its capture went quiet.
  bool get paused => _paused;

  /// Begins watching a share that just started on a window or a screen.
  void start({required bool windowShare}) {
    stop();
    _windowShare = windowShare;
    _timer = Timer.periodic(pollEvery, (_) => unawaited(poll()));
  }

  /// Stops watching; a share the watch had muted is left to the caller to end.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _watch.reset();
    _paused = false;
    _attempts = 0;
    _nextRestartAt = null;
  }

  Future<void> poll() async {
    if (_busy || _timer == null) return;
    _busy = true;
    try {
      final reading = await read();
      if (reading == null || _timer == null) return;
      final now = _clock();
      switch (_watch.observe(reading, windowShare: _windowShare, now: now)) {
        case ShareLiveness.frozen:
          await _onFrozen(now);
        case ShareLiveness.live:
          await _onLive();
        case ShareLiveness.unknown || ShareLiveness.suspect:
          break;
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _onFrozen(DateTime now) async {
    if (!_paused) {
      _paused = true;
      await pause(true);
    } else if (now.isBefore(_nextRestartAt ?? now)) {
      return;
    }
    final wait = retryAfter[_attempts.clamp(0, retryAfter.length - 1)];
    _attempts++;
    _nextRestartAt = now.add(wait);
    try {
      await restart();
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Could not restart the screen share capture; will retry',
        error,
        stack,
      );
      return;
    }
    _watch.reset();
    await pause(true);
  }

  Future<void> _onLive() async {
    if (!_paused) return;
    _paused = false;
    _attempts = 0;
    _nextRestartAt = null;
    await pause(false);
  }
}
