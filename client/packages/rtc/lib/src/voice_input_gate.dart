// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice session's microphone noise gate, level meter and the suppression
/// that feeds them.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show LogLevel;

import 'audio_device_switching.dart';
import 'input_gate.dart';
import 'mic_port.dart';
import 'noise_floor_estimator.dart';
import 'strong_noise_suppression.dart';

/// Smaller moves are not worth a native call or a slider repaint.
const double _kAutoThresholdStepDb = 0.5;

/// What [VoiceInputGate] needs from the session that owns it.
class VoiceInputGateHost {
  const VoiceInputGateHost({
    required this.refresh,
    required this.diag,
    required this.reopenCapture,
  });

  final void Function() refresh;
  final void Function(String line, {LogLevel level}) diag;
  final Future<void> Function(String reason) reopenCapture;
}

/// Owns the gate's settings and pushes them to the native [InputGateMonitor].
class VoiceInputGate {
  VoiceInputGate(
    this._host, {
    required this.gate,
    required this.mic,
    required this.switching,
  }) {
    strong = StrongNoiseSuppression(
      supported: gate.supported,
      supportsStrongest: gate.supported && supportsStrongestNoiseSuppression,
      onChanged: () => unawaited(apply()),
      log: _host.diag,
      webrtcNoiseSuppression: () => switching.processing.noiseSuppression,
    );
    _captureReadings = gate.readings.listen(
      (r) => strong.onReading(
        strongActive: r.strongActive,
        strongestActive: r.strongestActive,
        micOpen: mic.open,
        step: r.step,
      ),
    );
  }

  final VoiceInputGateHost _host;
  final InputGateMonitor gate;
  final MicPort mic;
  final AudioDeviceSwitching switching;
  late final StrongNoiseSuppression strong;
  late final StreamSubscription<InputGateReading> _captureReadings;
  bool _gateEnabled = true;
  double _gateThresholdDb = kDefaultInputThresholdDb;
  bool _evenOutLoudSounds = true;
  bool _levelDisplayed = false;
  NoiseFloorEstimator? _autoThreshold;
  StreamSubscription<InputGateReading>? _autoReadings;
  final _autoThresholds = StreamController<double>.broadcast();

  bool get supported => gate.supported;

  Future<void> dispose() async {
    await _captureReadings.cancel();
  }

  /// [enabled] false keeps metering and detecting voice; it only stops
  /// silencing the quiet frames.
  void setGate({required bool enabled, required double thresholdDb}) {
    _gateEnabled = enabled;
    if (_autoThreshold == null) {
      _gateThresholdDb = thresholdDb.clamp(kInputFloorDb, 0.0);
    }
    unawaited(apply());
  }

  /// Where the automatic threshold currently sits; emits only on a change
  /// worth sending to the native gate.
  Stream<double> get autoThresholds => _autoThresholds.stream;

  /// The threshold the native gate is using right now.
  double get thresholdDb => _gateThresholdDb;

  /// [enabled] hands the threshold to a [NoiseFloorEstimator] fed by the
  /// live level readings, starting from the current one; off keeps it where
  /// it ended up.
  void setAutoThreshold(bool enabled) {
    if (enabled == (_autoThreshold != null)) return;
    unawaited(_autoReadings?.cancel());
    _autoReadings = null;
    if (!enabled) {
      _autoThreshold = null;
      _host.refresh();
      return;
    }
    final estimator = _autoThreshold = NoiseFloorEstimator(
      initialThresholdDb: _gateThresholdDb,
    );
    _host.refresh();
    _autoReadings = gate.readings.listen((reading) {
      final next = estimator.add(reading.levelDb, interval: reading.step);
      if ((next - _gateThresholdDb).abs() < _kAutoThresholdStepDb) return;
      _gateThresholdDb = next;
      _autoThresholds.add(next);
      unawaited(apply());
    });
  }

  /// Whether a meter is on screen in a focused app; only then are readings taken at the display rate, otherwise just fast enough for the dead-mic watchdog, Strong fallback and automatic sensitivity, and not at all while the mic is closed.
  void setLevelDisplayed(bool displayed) {
    if (displayed == _levelDisplayed) return;
    _levelDisplayed = displayed;
    _host.refresh();
  }

  /// The slowest rate every consumer of a reading is happy with.
  void applyRate() => gate.setRate(_rate());

  InputGateRate _rate() {
    if (_levelDisplayed) return InputGateRate.display;
    if (!mic.open) return InputGateRate.off;
    if (_autoThreshold != null) return InputGateRate.adapt;
    return strong.watching ? InputGateRate.watch : InputGateRate.slow;
  }

  /// Softens shouts and caps sudden peaks on the microphone, where the
  /// host gates the input natively.
  void setEvenOutLoudSounds(bool enabled) {
    _evenOutLoudSounds = enabled;
    unawaited(apply());
  }

  /// Runs rnnoise on the microphone ahead of the gate, for keyboards, fans
  /// and room noise libwebrtc's own suppressor lets through; [strongest] adds
  /// DeepFilterNet, which costs more CPU.
  void setStrongNoiseSuppression(bool enabled, {bool strongest = false}) {
    final leveledBefore = levelsNatively;
    strong.setStrong(enabled, strongest: strongest);
    _host.refresh();
    unawaited(apply());
    // The chain takes over levelling from libwebrtc's auto gain, which is fixed when the capture opens.
    if (levelsNatively != leveledBefore &&
        switching.processing.autoGainControl) {
      unawaited(_host.reopenCapture('strong noise suppression changed'));
    }
  }

  /// Whether the chain lifts quiet speech itself: whenever a suppressor runs
  /// natively, since libwebrtc's auto gain ahead of it lifts quiet mouth
  /// sounds into the band the suppressor keeps.
  bool get levelsNatively => gate.supported && strong.nativeStrong;

  /// Sends the current settings to the native gate.
  Future<void> apply() => gate.configure(
        enabled: _gateEnabled,
        thresholdDb: _gateThresholdDb,
        dynamics: _evenOutLoudSounds,
        strongNoiseSuppression: strong.nativeStrong,
        strongestNoiseSuppression: strong.nativeStrongest,
        levelAfterSuppression: levelsNatively,
      );
}
