// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Giving the capture device back while muted, after a grace period in which
/// unmuting stays instant.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show LogLevel;

import 'voice_log.dart';

/// How long a mute keeps the device open before releasing it.
const Duration kMicReleaseGrace = Duration(seconds: 15);

/// Decides when a muted microphone's capture is released, and whether the
/// next unmute has to reopen it.
class MicRelease {
  MicRelease({
    required this.grace,
    required this.release,
    required this.mobile,
    this.log,
  });

  final Duration grace;
  final bool mobile;
  final VoiceLog? log;

  /// Stops the capture of the muted track; false when there was none to stop.
  final Future<bool> Function() release;

  Timer? _timer;
  bool _released = false;
  bool _keepReady = false;
  bool _backgrounded = false;
  bool _muted = false;

  /// Whether the device is closed, so the next unmute must reopen it.
  bool get released => _released;

  /// Push to talk wants instant key-down, so the device stays open.
  bool get keepReady => _keepReady;

  void onMuted() {
    _muted = true;
    _schedule();
  }

  /// Returns whether the unmute must reopen the capture.
  bool onUnmuting() {
    _timer?.cancel();
    _timer = null;
    _muted = false;
    return _released;
  }

  void setKeepReady(bool value) {
    _keepReady = value;
    _schedule();
  }

  void setBackgrounded(bool value) {
    _backgrounded = value;
    _schedule();
  }

  /// The capture is open again, by an unmute or by push to talk.
  void reopened() => _released = false;

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!_muted || _released) return;
    if (mobile && _backgrounded) {
      unawaited(_run());
      return;
    }
    if (_keepReady) return;
    _timer = Timer(grace, () => unawaited(_run()));
  }

  /// Gives the device back now, so the next unmute opens it with fresh options.
  Future<void> releaseNow() async {
    _timer?.cancel();
    await _run();
  }

  Future<void> _run() async {
    _timer = null;
    if (!_muted || _released) return;
    try {
      if (!await release()) return;
      _released = true;
      log?.call('Released the microphone capture while muted');
    } catch (e) {
      log?.call('Could not release the microphone: $e',
          level: LogLevel.warning);
    }
  }

  /// A new call starts with an open, unmuted capture.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _released = false;
    _muted = false;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
