// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s microphone noise gate and level meter, a mixin for the
/// reason `voice_session_audio_devices.dart` gives.
/// Smaller moves are not worth a native call or a slider repaint.
const double _kAutoThresholdStepDb = 0.5;

mixin VoiceSessionInputGate {
  lk.Room? get _room;
  AudioDeviceSwitching get _audioSwitching;
  late final MicPort _mic;
  late final InputGateMonitor _gate;
  late final StrongNoiseSuppression _strong;
  StreamSubscription<InputGateReading>? _captureReadings;
  bool _gateEnabled = true;
  double _gateThresholdDb = kDefaultInputThresholdDb;
  bool _evenOutLoudSounds = true;
  bool _levelDisplayed = false;
  NoiseFloorEstimator? _autoThreshold;
  StreamSubscription<InputGateReading>? _autoReadings;
  final _autoThresholds = StreamController<double>.broadcast();
  final _localLevels = StreamController<double>.broadcast();
  double _lastLocalLevel = 0;

  void _diag(String line, {LogLevel level});
  void _refreshParticipants();

  bool get supportsInputGate => _gate.supported;

  void _initCapture(MicPort? mic) {
    _mic = mic ?? LiveKitMicPort(() => _room);
    _strong = StrongNoiseSuppression(
      supported: _gate.supported,
      supportsStrongest: _gate.supported && supportsStrongestNoiseSuppression,
      onChanged: () => unawaited(_applyInputGate()),
      log: _diag,
      webrtcNoiseSuppression: () => _audioSwitching.processing.noiseSuppression,
    );
    _captureReadings = _gate.readings.listen(
      (r) => _strong.onReading(
        strongActive: r.strongActive,
        strongestActive: r.strongestActive,
        micOpen: _mic.open,
        step: r.step,
      ),
    );
  }

  Future<void> _disposeCapture() async {
    await _captureReadings?.cancel();
    await _localLevels.close();
  }

  /// What the next [MicPort.setEnabled] opens with. [reopen] makes LiveKit
  /// restart a capture that was released, rather than just unmute it.
  lk.AudioCaptureOptions _openCaptureOptions({required bool reopen}) =>
      _audioSwitching.captureOptions().copyWith(stopAudioCaptureOnMute: reopen);

  /// Your microphone's level and voice state, while in a call.
  Stream<InputGateReading> get inputGateReadings => _gate.readings;

  /// Your microphone's level as the SFU last reported it, for hosts with no input gate.
  /// Kept off the roster because a level change there rebuilds the whole call.
  Stream<double> get localAudioLevels => _localLevels.stream;

  void _reportLocalLevel(List<VoiceParticipant> roster) {
    final level = roster.where((p) => p.isLocal).firstOrNull?.audioLevel ?? 0;
    if (level == _lastLocalLevel) return;
    _lastLocalLevel = level;
    if (!_localLevels.isClosed) _localLevels.add(level);
  }

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
      _syncGateRate();
      return;
    }
    final estimator = _autoThreshold = NoiseFloorEstimator(
      initialThresholdDb: _gateThresholdDb,
    );
    _syncGateRate();
    _autoReadings = _gate.readings.listen((reading) {
      final next = estimator.add(reading.levelDb, interval: reading.step);
      if ((next - _gateThresholdDb).abs() < _kAutoThresholdStepDb) return;
      _gateThresholdDb = next;
      _autoThresholds.add(next);
      unawaited(_applyInputGate());
    });
  }

  /// Whether a meter is on screen in a focused app; only then are readings taken at the display rate, otherwise just fast enough for the dead-mic watchdog, Strong fallback and automatic sensitivity, and not at all while the mic is closed.
  void setLevelDisplayed(bool displayed) {
    if (displayed == _levelDisplayed) return;
    _levelDisplayed = displayed;
    _syncGateRate();
  }

  void _syncGateRate() => _refreshParticipants();

  /// The slowest rate every consumer of a reading is happy with.
  void _applyGateRate() => _gate.setRate(_gateRate());

  InputGateRate _gateRate() {
    if (_levelDisplayed) return InputGateRate.display;
    if (!_mic.open) return InputGateRate.off;
    if (_autoThreshold != null) return InputGateRate.adapt;
    return _strong.watching ? InputGateRate.watch : InputGateRate.slow;
  }

  /// Softens shouts and caps sudden peaks on the microphone, where the
  /// host gates the input natively.
  void setEvenOutLoudSounds(bool enabled) {
    _evenOutLoudSounds = enabled;
    unawaited(_applyInputGate());
  }

  /// Runs rnnoise on the microphone ahead of the gate, for keyboards, fans
  /// and room noise libwebrtc's own suppressor lets through; [strongest] adds
  /// DeepFilterNet, which costs more CPU.
  void setStrongNoiseSuppression(bool enabled, {bool strongest = false}) {
    final leveledBefore = _levelsNatively;
    _strong.setStrong(enabled, strongest: strongest);
    _syncGateRate();
    unawaited(_applyInputGate());
    // The chain takes over levelling from libwebrtc's auto gain, which is fixed when the capture opens.
    if (_levelsNatively != leveledBefore &&
        _audioSwitching.processing.autoGainControl) {
      unawaited(_reopenCapture('strong noise suppression changed'));
    }
  }

  /// Whether the chain lifts quiet speech itself: whenever a suppressor runs
  /// natively, since libwebrtc's auto gain ahead of it lifts quiet mouth
  /// sounds into the band the suppressor keeps.
  bool get _levelsNatively => _gate.supported && _strong.nativeStrong;

  Future<void> _reopenCapture(String reason);

  Future<void> _applyInputGate() => _gate.configure(
        enabled: _gateEnabled,
        thresholdDb: _gateThresholdDb,
        dynamics: _evenOutLoudSounds,
        strongNoiseSuppression: _strong.nativeStrong,
        strongestNoiseSuppression: _strong.nativeStrongest,
        levelAfterSuppression: _levelsNatively,
      );
}
