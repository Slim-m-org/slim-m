// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s microphone noise gate and level meter, a mixin for the
/// reason `voice_session_audio_devices.dart` gives.
/// Smaller moves are not worth a native call or a slider repaint.
const double _kAutoThresholdStepDb = 0.5;

mixin VoiceSessionInputGate {
  late final InputGateMonitor _gate;
  bool _gateEnabled = true;
  double _gateThresholdDb = kDefaultInputThresholdDb;
  bool _evenOutLoudSounds = true;
  bool _strongNoiseSuppression = false;
  NoiseFloorEstimator? _autoThreshold;
  StreamSubscription<InputGateReading>? _autoReadings;
  final _autoThresholds = StreamController<double>.broadcast();

  bool get supportsInputGate => _gate.supported;

  /// Your microphone's level and voice state, while in a call.
  Stream<InputGateReading> get inputGateReadings => _gate.readings;

  /// [enabled] false keeps metering and detecting voice; it only stops
  /// silencing the quiet frames.
  void setInputGate({required bool enabled, required double thresholdDb}) {
    _gateEnabled = enabled;
    if (_autoThreshold == null) {
      _gateThresholdDb = thresholdDb.clamp(kInputFloorDb, 0.0);
    }
    unawaited(_applyInputGate());
  }

  /// Where the automatic threshold currently sits; emits only on a change
  /// worth sending to the native gate.
  Stream<double> get autoInputThresholds => _autoThresholds.stream;

  /// The threshold the native gate is using right now.
  double get inputThresholdDb => _gateThresholdDb;

  /// [enabled] hands the threshold to a [NoiseFloorEstimator] fed by the
  /// live level readings, starting from the current one; off keeps it where
  /// it ended up.
  void setAutoInputThreshold(bool enabled) {
    if (enabled == (_autoThreshold != null)) return;
    unawaited(_autoReadings?.cancel());
    _autoReadings = null;
    if (!enabled) {
      _autoThreshold = null;
      return;
    }
    final estimator = _autoThreshold = NoiseFloorEstimator(
      initialThresholdDb: _gateThresholdDb,
    );
    _autoReadings = _gate.readings.listen((reading) {
      final next = estimator.add(reading.levelDb);
      if ((next - _gateThresholdDb).abs() < _kAutoThresholdStepDb) return;
      _gateThresholdDb = next;
      _autoThresholds.add(next);
      unawaited(_applyInputGate());
    });
  }

  /// Softens shouts and caps sudden peaks on the microphone, where the
  /// host gates the input natively.
  void setEvenOutLoudSounds(bool enabled) {
    _evenOutLoudSounds = enabled;
    unawaited(_applyInputGate());
  }

  /// Runs rnnoise on the microphone ahead of the gate, for keyboards, fans
  /// and room noise libwebrtc's own suppressor lets through.
  void setStrongNoiseSuppression(bool enabled) {
    _strongNoiseSuppression = enabled;
    unawaited(_applyInputGate());
  }

  Future<void> _applyInputGate() => _gate.configure(
        enabled: _gateEnabled,
        thresholdDb: _gateThresholdDb,
        dynamics: _evenOutLoudSounds,
        strongNoiseSuppression: _strongNoiseSuppression,
      );
}
