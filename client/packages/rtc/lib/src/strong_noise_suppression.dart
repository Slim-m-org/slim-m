// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strong (rnnoise) runs natively on top of libwebrtc's own suppression, which
/// stays on throughout: rnnoise alone passes steady hiss and hum that
/// libwebrtc removes first, so toggling Strong never reopens the capture.
library;

import 'package:slimm_api/api.dart' show LogLevel;

import 'input_gate.dart' show kInputGateDisplayInterval;
import 'strong_inactivity.dart';
import 'voice_log.dart';

class StrongNoiseSuppression {
  StrongNoiseSuppression({
    required this.supported,
    required this.onChanged,
    this.log,
  });

  /// Where Strong's decisions are written, so a copied debug log explains a noisy mic.
  final VoiceLog? log;

  /// Only hosts with the native input gate can run rnnoise at all.
  final bool supported;

  /// The native rnnoise flag changed, so the gate must be reconfigured.
  final void Function() onChanged;

  final _tracker = StrongInactivityTracker();
  bool _strong = false;
  bool _reportedActive = false;
  bool _inactiveLogged = false;

  /// Whether the native gate should run rnnoise.
  bool get nativeStrong => _strong;

  /// Whether rnnoise is meant to be running, so its liveness is being watched.
  bool get watching => supported && _strong;

  void setStrong(bool strong) {
    if (strong == _strong) return;
    _strong = strong;
    _log('choice strong=${strong ? 'on' : 'off'}');
    _clearReadings();
    onChanged();
  }

  /// A new call opens a new track; nothing about the last one carries over.
  void reset() {
    _log('new call, state cleared');
    _clearReadings();
  }

  void onReading({
    required bool strongActive,
    required bool micOpen,
    Duration step = kInputGateDisplayInterval,
  }) {
    if (!watching || !micOpen) {
      _tracker.reset();
      return;
    }
    if (strongActive && !_reportedActive) {
      _reportedActive = true;
      _log('strong active');
    }
    final inactive = _tracker.add(strongActive: strongActive, step: step);
    if (inactive == _inactiveLogged) return;
    _inactiveLogged = inactive;
    _log(
      inactive
          ? 'strong inactive for ${kStrongInactiveFor.inSeconds}s, libwebrtc '
              'suppression still on'
          : 'strong active again',
      level: inactive ? LogLevel.warning : LogLevel.info,
    );
  }

  void _clearReadings() {
    _reportedActive = false;
    _inactiveLogged = false;
    _tracker.reset();
  }

  void _log(String message, {LogLevel level = LogLevel.info}) => log?.call(
        'voice-ns: $message (strong=${_strong ? 'on' : 'off'} webrtc_ns=on)',
        level: level,
      );
}
