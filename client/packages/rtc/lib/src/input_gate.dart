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

/// DeepFilterNet ("Strongest") is built into the same Linux and Windows
/// plugin; a build without its model falls back to Strong inside the plugin.
bool get supportsStrongestNoiseSuppression => supportsInputGate;

/// One read of the native gate.
class InputGateReading {
  const InputGateReading({
    required this.levelDb,
    required this.voice,
    this.strongActive = false,
    this.strongestActive = false,
    this.step = kInputGateDisplayInterval,
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

  /// Whether DeepFilterNet processed the last frame; false with Strongest on
  /// means rnnoise alone is running because the model could not.
  final bool strongestActive;

  /// The poll interval this reading covers, so consumers that count time
  /// stay right when the rate changes.
  final Duration step;
}

/// How often the gate is read while a meter is on screen and the app is focused.
const Duration kInputGateDisplayInterval = Duration(milliseconds: 50);

/// How fast the gate is read, as a multiple of the display interval.
enum InputGateRate {
  /// A meter or speaking ring is on screen in a focused app.
  display(1),

  /// Nothing is displayed but automatic sensitivity is adapting: 200 ms.
  adapt(4),

  /// Nothing is displayed but Strong runs: 1 s, enough for the Strong
  /// fallback (2 s of polls).
  watch(20),

  /// Only the dead-mic watchdog reads, and it needs 10 s of silence: 2 s.
  slow(40),

  /// Nothing consumes a reading (the microphone is closed): no polling.
  off(0);

  const InputGateRate(this.multiple);

  final int multiple;
}

/// [levelDb] as 0 to 1 across the meter's range.
double inputLevelFraction(double levelDb) =>
    ((levelDb - kInputFloorDb) / -kInputFloorDb).clamp(0.0, 1.0);

/// Configures the gate and, while [start]ed, polls it for the level and the
/// voice state. Does nothing where [supportsInputGate] is false.
class InputGateMonitor {
  InputGateMonitor({
    Duration interval = kInputGateDisplayInterval,
    Future<Object?> Function(String method, [Object? args])? invoke,
    bool? supported,
  })  : displayInterval = interval,
        _invoke = invoke ?? _invokeNative,
        _supported = supported ?? supportsInputGate;

  /// A monitor that never touches the platform, for a session whose room is
  /// not a real one.
  InputGateMonitor.disabled() : this(supported: false);

  /// The display rate; every other [InputGateRate] is a multiple of it.
  final Duration displayInterval;
  final bool _supported;
  final Future<Object?> Function(String method, [Object? args]) _invoke;

  final _levels = StreamController<InputGateReading>.broadcast();
  Timer? _timer;
  bool _started = false;
  bool _polling = false;
  bool _voice = false;
  InputGateRate _rate = InputGateRate.display;
  void Function()? _onVoiceChanged;

  /// Readings while started, about every [interval].
  Stream<InputGateReading> get readings => _levels.stream;

  bool get supported => _supported;

  /// The last voice state read; false while stopped.
  bool get voice => _voice;

  bool get running => _started;

  InputGateRate get rate => _rate;

  /// Zero while the rate is [InputGateRate.off].
  Duration get interval => displayInterval * _rate.multiple;

  /// Whether readings come fast enough to draw a meter or a speaking ring.
  bool get fast => running && _rate == InputGateRate.display;

  /// Changes the poll rate; a running monitor keeps its voice callback.
  void setRate(InputGateRate next) {
    if (next == _rate) return;
    _rate = next;
    if (_started) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final onVoiceChanged = _onVoiceChanged;
    if (onVoiceChanged == null) return;
    if (_rate == InputGateRate.off) {
      _voice = false;
      return;
    }
    _timer = Timer.periodic(interval, (_) => _poll(onVoiceChanged));
  }

  static Future<Object?> _invokeNative(String method, [Object? args]) =>
      rtc.WebRTC.invokeMethod<Object?, Object?>(method, args);

  /// [dynamics] turns on the compressor and limiter that run after the gate;
  /// [strongNoiseSuppression] the rnnoise stage that runs before it, and
  /// [strongestNoiseSuppression] DeepFilterNet beside it.
  Future<void> configure({
    required bool enabled,
    required double thresholdDb,
    required bool dynamics,
    bool strongNoiseSuppression = false,
    bool strongestNoiseSuppression = false,
  }) async {
    if (!_supported) return;
    try {
      await _invoke('setInputGate', {
        'enabled': enabled,
        'thresholdDb': thresholdDb,
        'dynamics': dynamics,
        'strongNoiseSuppression': strongNoiseSuppression,
        'strongestNoiseSuppression': strongestNoiseSuppression,
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
    if (!_supported || _started) return;
    _started = true;
    _onVoiceChanged = onVoiceChanged;
    _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
    _onVoiceChanged = null;
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
        strongestActive: raw['strongestNoiseSuppression'] == true,
        step: kInputGateDisplayInterval * _rate.multiple,
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
