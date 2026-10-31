// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strong (rnnoise) and Strongest (DeepFilterNet, with rnnoise beside it) run natively on top of libwebrtc's own suppression, which
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
    this.supportsStrongest = false,
    required this.onChanged,
    this.log,
    this.webrtcNoiseSuppression = _alwaysOn,
  });

  static bool _alwaysOn() => true;

  /// Whether libwebrtc's own suppression is on, for the log lines.
  final bool Function() webrtcNoiseSuppression;

  /// Where Strong's decisions are written, so a copied debug log explains a noisy mic.
  final VoiceLog? log;

  /// Only hosts with the native input gate can run rnnoise at all.
  final bool supported;

  /// The native rnnoise flag changed, so the gate must be reconfigured.
  final void Function() onChanged;

  final _tracker = StrongInactivityTracker();
  bool _strong = false;
  bool _strongest = false;
  bool _reportedActive = false;
  bool _inactiveLogged = false;

  /// Whether the native gate should run rnnoise; Strongest keeps it running
  /// beside DeepFilterNet.
  bool get nativeStrong => _strong || _strongest;

  /// Whether the native gate should run DeepFilterNet, which it can only do
  /// where the host supports it.
  bool get nativeStrongest => _strongest && supportsStrongest;

  /// Whether DeepFilterNet can run on this host at all.
  final bool supportsStrongest;

  /// Whether rnnoise is meant to be running, so its liveness is being watched.
  bool get watching => supported && (_strong || _strongest);

  /// [strongest] without host support is Strong, so a call never has less
  /// suppression than the member picked.
  void setStrong(bool strong, {bool strongest = false}) {
    if (strong == _strong && strongest == _strongest) return;
    _strong = strong;
    _strongest = strongest;
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
    bool strongestActive = false,
    required bool micOpen,
    Duration step = kInputGateDisplayInterval,
  }) {
    if (!watching || !micOpen) {
      _tracker.reset();
      return;
    }
    final active = nativeStrongest ? strongestActive : strongActive;
    if (active && !_reportedActive) {
      _reportedActive = true;
      _log('${_name()} active');
    }
    final inactive = _tracker.add(strongActive: active, step: step);
    if (inactive == _inactiveLogged) return;
    _inactiveLogged = inactive;
    _log(
      inactive
          ? '${_name()} inactive for ${kStrongInactiveFor.inSeconds}s, '
              'libwebrtc suppression still on'
          : '${_name()} active again',
      level: inactive ? LogLevel.warning : LogLevel.info,
    );
  }

  String _name() => nativeStrongest ? 'strongest' : 'strong';

  void _clearReadings() {
    _reportedActive = false;
    _inactiveLogged = false;
    _tracker.reset();
  }

  void _log(String message, {LogLevel level = LogLevel.info}) => log?.call(
        'voice-ns: $message (strong=${_strong ? 'on' : 'off'} '
        'strongest=${nativeStrongest ? 'on' : 'off'} '
        'webrtc_ns=${webrtcNoiseSuppression() ? 'on' : 'off'})',
        level: level,
      );
}
