// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone noise gate and level meter in slim-m's flutter-webrtc fork,
/// which runs on every 10ms capture frame; see docs/voice-input-gate.md.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

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
  const InputGateReading({required this.levelDb, required this.voice});

  /// Capture level in dBFS, before the gate.
  final double levelDb;

  /// Whether the level crossed the threshold within the hold time.
  final bool voice;
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

  Future<void> configure({
    required bool enabled,
    required double thresholdDb,
  }) async {
    if (!_supported) return;
    try {
      await _invoke('setInputGate', {
        'enabled': enabled,
        'thresholdDb': thresholdDb,
      });
    } on Object {
      // An older native build has no gate; the call then just carries on ungated.
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
      );
      if (!_levels.isClosed) _levels.add(reading);
      if (reading.voice != _voice) {
        _voice = reading.voice;
        onVoiceChanged();
      }
    } on Object {
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
