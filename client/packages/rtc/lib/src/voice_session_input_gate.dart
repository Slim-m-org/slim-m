// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s microphone noise gate and level meter, a mixin for the
/// reason `voice_session_audio_devices.dart` gives.
/// Smaller moves are not worth a native call or a slider repaint.
const double _kAutoThresholdStepDb = 0.5;

mixin VoiceSessionInputGate {
  lk.Room? get _room;
  AudioDeviceSwitching get _audioSwitching;
  late final InputGateMonitor _gate;
  late final CaptureNoiseSuppression _capture;
  StreamSubscription<InputGateReading>? _captureReadings;
  bool _gateEnabled = true;
  double _gateThresholdDb = kDefaultInputThresholdDb;
  bool _evenOutLoudSounds = true;
  NoiseFloorEstimator? _autoThreshold;
  StreamSubscription<InputGateReading>? _autoReadings;
  final _autoThresholds = StreamController<double>.broadcast();

  bool get supportsInputGate => _gate.supported;

  void _initCapture() {
    _capture = CaptureNoiseSuppression(
      supported: _gate.supported,
      restart: _restartCapture,
      canRestart: () => _micOpen && _gateEnabled,
      onNativeStrongChanged: () => unawaited(_applyInputGate()),
    );
    _captureReadings = _gate.readings.listen(
      (r) =>
          _capture.onReading(strongActive: r.strongActive, micOpen: _micOpen),
    );
  }

  Future<void> _disposeCapture() async {
    _capture.dispose();
    await _captureReadings?.cancel();
  }

  lk.LocalTrackPublication<lk.LocalAudioTrack>? get _micPublication {
    final all = _room?.localParticipant?.audioTrackPublications;
    for (final p in all ?? <lk.LocalTrackPublication<lk.LocalAudioTrack>>[]) {
      if (p.source == lk.TrackSource.microphone) return p;
    }
    return null;
  }

  bool get _micOpen {
    final pub = _micPublication;
    return pub != null && !pub.muted;
  }

  /// Null leaves the room's defaults, which is all a host without the gate needs.
  lk.AudioCaptureOptions? _micCaptureOptions() => _gate.supported
      ? _audioSwitching.captureOptions(
          noiseSuppression: _capture.webrtcNoiseSuppression,
        )
      : null;

  Future<void> _restartCapture({required bool webrtcNoiseSuppression}) async {
    final track = _micPublication?.track;
    if (track == null) return;
    await track.restartTrack(
      _audioSwitching.captureOptions(noiseSuppression: webrtcNoiseSuppression),
    );
  }

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
    _capture.setStrong(enabled);
    unawaited(_applyInputGate());
  }

  Future<void> _applyInputGate() => _gate.configure(
        enabled: _gateEnabled,
        thresholdDb: _gateThresholdDb,
        dynamics: _evenOutLoudSounds,
        strongNoiseSuppression: _capture.nativeStrong,
      );
}
