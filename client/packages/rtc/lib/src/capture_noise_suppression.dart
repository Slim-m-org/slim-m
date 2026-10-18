// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the microphone is captured with libwebrtc's own noise suppression.
/// Strong (rnnoise) alone beats libwebrtc followed by rnnoise, so Strong opens
/// the mic with it off; this keeps at least one suppressor running throughout.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show LogLevel;

import 'input_gate.dart' show kInputGateDisplayInterval;
import 'strong_inactivity.dart';
import 'voice_log.dart';

/// Longest wait between restart attempts after a failure.
const Duration kMaxRestartBackoff = Duration(seconds: 30);

/// How long a wanted restart waits, so rapid toggles collapse into one.
const Duration kCaptureRestartDebounce = Duration(seconds: 1);

class CaptureNoiseSuppression {
  CaptureNoiseSuppression({
    required this.supported,
    required this.restart,
    required this.canRestart,
    required this.onNativeStrongChanged,
    this.debounce = kCaptureRestartDebounce,
    this.log,
  });

  /// Where Strong's decisions are written, so a copied debug log explains a noisy mic.
  final VoiceLog? log;

  /// Only hosts with the native input gate can run rnnoise at all.
  final bool supported;

  /// Reopens the live mic track with libwebrtc noise suppression on or off.
  final Future<void> Function({required bool webrtcNoiseSuppression}) restart;

  /// False while muted or on push-to-talk: a restart then can open a muted mic.
  final bool Function() canRestart;

  /// The native rnnoise flag changed, so the gate must be reconfigured.
  final void Function() onNativeStrongChanged;

  final Duration debounce;

  final _tracker = StrongInactivityTracker();
  bool _strong = false;
  bool _reportedActive = false;
  bool _fallback = false;
  bool _captureOff = false;
  bool _disposed = false;
  bool _inFlight = false;
  int _failures = 0;
  int _generation = 0;
  Timer? _timer;

  /// What a track opened now should use.
  bool get webrtcNoiseSuppression => !(supported && _strong && !_fallback);

  /// Strong stays on natively until the open track has libwebrtc's back, so
  /// a switch to Standard never leaves the mic with nothing.
  bool get nativeStrong => _strong || _captureOff;

  bool get _mismatch => webrtcNoiseSuppression == _captureOff;

  void setStrong(bool strong) {
    if (strong == _strong) return;
    _strong = strong;
    _log('Strong noise suppression turned ${strong ? 'on' : 'off'}');
    _resetFallback();
    onNativeStrongChanged();
    _schedule();
  }

  /// The input device changed, so what its sample rate allowed is unknown.
  /// Call [retry] once the switch has settled.
  void deviceChanged() => _resetFallback();

  /// Strong could not reopen the capture, so stay on libwebrtc's suppressor
  /// until the device changes.
  void fallBack() {
    if (_fallback) return;
    _fallback = true;
    _log(
      'Strong could not reopen the microphone; using standard suppression',
      level: LogLevel.warning,
    );
    _tracker.reset();
  }

  /// A new call opens a new track; nothing about the last one carries over.
  void reset() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _failures = 0;
    _resetFallback();
    final wasOff = _captureOff;
    _captureOff = false;
    if (wasOff) onNativeStrongChanged();
  }

  /// A track was just opened with [webrtcNoiseSuppression].
  void opened({required bool webrtcNoiseSuppression}) {
    final off = !webrtcNoiseSuppression;
    if (off == _captureOff) return;
    _captureOff = off;
    onNativeStrongChanged();
  }

  void onReading({
    required bool strongActive,
    required bool micOpen,
    Duration step = kInputGateDisplayInterval,
  }) {
    if (!supported || !_strong || !micOpen) {
      _tracker.reset();
      return;
    }
    if (strongActive && !_reportedActive) {
      _reportedActive = true;
      _log('Strong noise suppression is running on this microphone');
    }
    if (_tracker.add(strongActive: strongActive, step: step) && !_fallback) {
      _fallback = true;
      _log(
        'Strong noise suppression cannot run on this microphone; using standard',
        level: LogLevel.warning,
      );
      _schedule();
    }
  }

  /// Retries a restart that was waiting for the mic to open.
  void retry() => _schedule();

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  void _resetFallback() {
    _fallback = false;
    _reportedActive = false;
    _tracker.reset();
  }

  void _log(String message, {LogLevel level = LogLevel.info}) =>
      log?.call(message, level: level);

  void _schedule() {
    if (_disposed || _inFlight) return;
    if (!_mismatch) {
      _timer?.cancel();
      _timer = null;
      _failures = 0;
      return;
    }
    if (!canRestart()) return;
    _timer ??= Timer(debounce, _run);
  }

  Future<void> _run() async {
    _timer = null;
    if (_disposed || _inFlight || !_mismatch) return;
    if (!canRestart()) {
      if (_failures > 0) _rearm();
      return;
    }
    final want = webrtcNoiseSuppression;
    final generation = _generation;
    _inFlight = true;
    try {
      await restart(webrtcNoiseSuppression: want);
      if (_disposed || generation != _generation) return;
      _failures = 0;
      opened(webrtcNoiseSuppression: want);
    } on Object catch (error) {
      if (generation == _generation) {
        _log(
          'Could not restart the microphone for noise suppression: $error',
          level: LogLevel.warning,
        );
        _failures++;
        _rearm();
      }
    } finally {
      _inFlight = false;
    }
    if (generation == _generation) _schedule();
  }

  /// Backs off up to [kMaxRestartBackoff] so a room mid-reconnect is not hammered.
  void _rearm() {
    final scaled = debounce * (1 << _failures.clamp(0, 5));
    final delay = scaled > kMaxRestartBackoff ? kMaxRestartBackoff : scaled;
    _timer = Timer(delay, _run);
  }
}
