// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the microphone is captured with libwebrtc's own noise suppression.
/// Strong (rnnoise) alone beats libwebrtc followed by rnnoise, so Strong opens
/// the mic with it off; this keeps at least one suppressor running throughout.
library;

import 'dart:async';

import 'strong_inactivity.dart';

class CaptureNoiseSuppression {
  CaptureNoiseSuppression({
    required this.supported,
    required this.restart,
    required this.canRestart,
    required this.onNativeStrongChanged,
    this.debounce = const Duration(seconds: 1),
  });

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
  bool _fallback = false;
  bool _captureOff = false;
  Timer? _timer;

  /// What a track opened now should use.
  bool get webrtcNoiseSuppression => !(supported && _strong && !_fallback);

  /// Strong stays on natively until the open track has libwebrtc's back, so
  /// a switch to Standard never leaves the mic with nothing.
  bool get nativeStrong => _strong || _captureOff;

  void setStrong(bool strong) {
    if (strong == _strong) return;
    _strong = strong;
    _resetFallback();
    onNativeStrongChanged();
    _schedule();
  }

  /// The input device changed, so what its sample rate allowed is unknown.
  void deviceChanged() {
    _resetFallback();
    _schedule();
  }

  /// A track was just opened with [webrtcNoiseSuppression].
  void opened({required bool webrtcNoiseSuppression}) {
    final off = !webrtcNoiseSuppression;
    if (off == _captureOff) return;
    _captureOff = off;
    onNativeStrongChanged();
  }

  void onReading({required bool strongActive, required bool micOpen}) {
    if (!supported || !_strong || !micOpen) {
      _tracker.reset();
      return;
    }
    if (_tracker.add(strongActive: strongActive) && !_fallback) {
      _fallback = true;
      _schedule();
    }
  }

  /// Retries a restart that was waiting for the mic to open.
  void retry() => _schedule();

  void dispose() => _timer?.cancel();

  void _resetFallback() {
    _fallback = false;
    _tracker.reset();
  }

  void _schedule() {
    if (webrtcNoiseSuppression == !_captureOff) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (!canRestart()) return;
    _timer ??= Timer(debounce, _run);
  }

  Future<void> _run() async {
    _timer = null;
    final want = webrtcNoiseSuppression;
    if (want == !_captureOff || !canRestart()) return;
    try {
      await restart(webrtcNoiseSuppression: want);
      opened(webrtcNoiseSuppression: want);
    } on Object {
      // The old track keeps running, and nativeStrong still covers it.
    }
  }
}
