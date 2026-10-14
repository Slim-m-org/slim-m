// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s microphone noise gate and level meter, a mixin for the
/// reason `voice_session_audio_devices.dart` gives.
mixin VoiceSessionInputGate {
  late final InputGateMonitor _gate;
  bool _gateEnabled = true;
  double _gateThresholdDb = kDefaultInputThresholdDb;

  bool get supportsInputGate => _gate.supported;

  /// Your microphone's level and voice state, while in a call.
  Stream<InputGateReading> get inputGateReadings => _gate.readings;

  /// [enabled] false keeps metering and detecting voice; it only stops
  /// silencing the quiet frames.
  void setInputGate({required bool enabled, required double thresholdDb}) {
    _gateEnabled = enabled;
    _gateThresholdDb = thresholdDb.clamp(kInputFloorDb, 0.0);
    unawaited(_applyInputGate());
  }

  Future<void> _applyInputGate() =>
      _gate.configure(enabled: _gateEnabled, thresholdDb: _gateThresholdDb);
}
