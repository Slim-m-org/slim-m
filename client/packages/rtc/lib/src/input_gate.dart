// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone noise gate and level meter in slim-m's flutter-webrtc fork,
/// which runs on every 10ms capture frame; see docs/voice-input-gate.md.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show AppLog, LogTag, reportFailure;

/// Quietest level the meter and the threshold slider show.
const double kInputFloorDb = -80.0;

/// Where the threshold starts: above a quiet room, well below speech once
/// auto gain control has levelled it.
const double kDefaultInputThresholdDb = -50.0;

/// Only the fork's shared desktop C++ (Linux and Windows) has the gate.
bool get supportsInputGate =>
    lk.lkPlatformIs(lk.PlatformType.linux) ||
    lk.lkPlatformIs(lk.PlatformType.windows);

/// One read of the native gate.
class InputGateReading {
  const InputGateReading({
    required this.levelDb,
    required this.voice,
    this.strongActive = false,
  });

  /// The loudest 10ms frame since the last reading, in dBFS: the signal that
  /// is sent, after noise suppression and before the gate, and the very level
  /// the threshold is compared with.
  final double levelDb;

  /// Whether the gate is letting audio through: a frame crossed the threshold
  /// within the hold time and, with Strong, rnnoise heard speech or a clearly
  /// louder sound.
  final bool voice;

  /// Whether rnnoise processed the last frame; false when it is off, or on a
  /// plugin too old to resample a capture that is not 48 kHz.
  final bool strongActive;
}

/// [levelDb] as 0 to 1 across the meter's range.
double inputLevelFraction(double levelDb) =>
    ((levelDb - kInputFloorDb) / -kInputFloorDb).clamp(0.0, 1.0);

/// Configures the gate and, while [start]ed, polls it for the level and the
/// voice state. Does nothing where [supportsInputGate] is false.
class InputGateMonitor {
  InputGateMonitor({
    this.interval = const Duration(milliseconds: 50),
    Future<Object?> Function(String method, [Object? args])? invoke,
    bool? supported,
  })  : _invoke = invoke ?? _invokeNative,
        _supported = supported ?? supportsInputGate;

  /// A monitor that never touches the platform, for a session whose room is
  /// not a real one.
  InputGateMonitor.disabled() : this(supported: false);

  final Duration interval;
  final bool _supported;
  final Future<Object?> Function(String method, [Object? args]) _invoke;

  final _levels = StreamController<InputGateReading>.broadcast();
  Timer? _timer;
  bool _polling = false;
  bool _voice = false;

  /// Readings while started, about every [interval].
  Stream<InputGateReading> get readings => _levels.stream;

  bool get supported => _supported;

  /// The last voice state read; false while stopped.
  bool get voice => _voice;

  bool get running => _timer != null;

  static Future<Object?> _invokeNative(String method, [Object? args]) =>
      rtc.WebRTC.invokeMethod<Object?, Object?>(method, args);

  /// [dynamics] turns on the compressor and limiter that run after the gate;
  /// [strongNoiseSuppression] the rnnoise stage that runs before it.
  Future<void> configure({
    required bool enabled,
    required double thresholdDb,
    required bool dynamics,
    bool strongNoiseSuppression = false,
  }) async {
    if (!_supported) return;
    try {
      await _invoke('setInputGate', {
        'enabled': enabled,
        'thresholdDb': thresholdDb,
        'dynamics': dynamics,
        'strongNoiseSuppression': strongNoiseSuppression,
      });
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'This build has no voice input gate; the call runs ungated',
          error,
          stack);
    }
  }

  /// [onVoiceChanged] runs whenever the voice state flips.
  void start(void Function() onVoiceChanged) {
    if (!_supported || _timer != null) return;
    _timer = Timer.periodic(interval, (_) => _poll(onVoiceChanged));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _voice = false;
  }

  Future<void> _poll(void Function() onVoiceChanged) async {
    if (_polling) return;
    _polling = true;
    try {
      final raw = await _invoke('getInputGate');
      if (_timer == null || raw is! Map) return;
      final reading = InputGateReading(
        levelDb: (raw['levelDb'] as num?)?.toDouble() ?? kInputFloorDb,
        voice: raw['voice'] == true,
        strongActive: raw['strongNoiseSuppression'] == true,
      );
      if (!_levels.isClosed) _levels.add(reading);
      if (reading.voice != _voice) {
        _voice = reading.voice;
        onVoiceChanged();
      }
    } on Object catch (error, stack) {
      reportFailure(LogTag.voice,
          'read the microphone level from the input gate', error, stack);
      stop();
    } finally {
      _polling = false;
    }
  }

  Future<void> dispose() async {
    stop();
    await _levels.close();
  }
}
