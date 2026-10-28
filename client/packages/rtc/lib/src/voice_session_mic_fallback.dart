// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The switch to another microphone once the watchdog has given up on the one
/// in use; the choice in the session and the saved settings is never touched.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show LogLevel;

import 'audio_device_switching.dart';
import 'input_gate.dart';
import 'mic_failure.dart';
import 'mic_fallback.dart';
import 'mic_port.dart';
import 'mic_recovery.dart';
import 'voice_models.dart';

/// What [MicFallback] needs from the session that owns it.
class MicFallbackHost {
  const MicFallbackHost({
    required this.switching,
    required this.hasRoom,
    required this.micWanted,
    required this.mic,
    required this.timing,
    required this.watchdog,
    required this.log,
    required this.setStatus,
    required this.noteFailure,
    required this.restartCapture,
    required this.selectInput,
    required this.selectOutput,
  });

  final AudioDeviceSwitching Function() switching;
  final bool Function() hasRoom;
  final bool Function() micWanted;
  final MicPort Function() mic;
  final MicRecoveryTiming Function() timing;
  final SilentMicWatchdog Function() watchdog;
  final void Function(String message, {LogLevel level}) log;
  final void Function(MicStatus status) setStatus;
  final Future<void> Function(MicFailureReason reason) noteFailure;
  final Future<bool> Function(String reason) restartCapture;

  /// Both move only the live device, never the remembered choice.
  final Future<bool> Function(AudioDevice? device) selectInput;
  final Future<bool> Function(AudioDevice? device) selectOutput;
}

class MicFallback {
  MicFallback(this._host);

  final MicFallbackHost _host;

  /// Whether a silent microphone is swapped for another.
  bool enabled = true;

  /// The generation whose run is in flight; a [reset] makes it stale at once rather than when it unwinds.
  int? _runningGeneration;
  int _generation = 0;
  final _tried = <String>{};
  String? _loggedInputNames;
  String? _notice;
  final _notices = StreamController<String?>.broadcast();

  /// The microphone the call switched to on its own, until dismissed.
  String? get notice => _notice;
  Stream<String?> get notices => _notices.stream;

  void dismissNotice() => _setNotice(null);

  void _setNotice(String? next) {
    if (next == _notice) return;
    _notice = next;
    if (!_notices.isClosed) _notices.add(next);
  }

  /// Ends the call's fallback: a run in flight stops quietly and the choice returns.
  void reset() {
    _generation++;
    _tried.clear();
    _loggedInputNames = null;
    _setNotice(null);
    _host.switching().endFallback();
  }

  Future<void> dispose() => _notices.close();

  /// The chosen microphone and speaker, as labels, for a tester's log.
  Future<void> logDevices(String why) async {
    final switching = _host.switching();
    try {
      final mic = await switching.inputDeviceInUse();
      final speaker = await switching.outputDeviceInUse();
      _host.log(
        'Audio devices ($why): mic ${describeDevice(mic, followsDefault: switching.followsSystemDefaultInput)}; '
        'speaker ${describeDevice(speaker, followsDefault: switching.followsSystemDefaultOutput)}',
      );
    } on Object catch (e) {
      _host.log('Could not read the audio devices: $e',
          level: LogLevel.warning);
    }
  }

  /// Logs the microphone names once, and again whenever the list changes.
  Future<void> logInputList() async {
    try {
      final names = [
        for (final d in await _host.switching().inputs())
          d.label.isEmpty ? 'unnamed' : d.label,
      ].join(' | ');
      if (names == _loggedInputNames) return;
      _loggedInputNames = names;
      _host.log('Microphones: ${names.isEmpty ? 'none listed' : names}');
    } on Object catch (e) {
      _host.log('Could not list microphones: $e', level: LogLevel.warning);
    }
  }

  /// Whether the call that started a run is still the one it should report to.
  bool _live(int generation) =>
      generation == _generation && _host.hasRoom() && _host.micWanted();

  /// Tries each other microphone once, the system default first; keeps the
  /// first that is not silent, and leaves the mic unavailable otherwise.
  ///
  /// Hosts that cannot pick a microphone (mobile) have nothing to switch to.
  Future<void> run() async {
    if (_runningGeneration == _generation ||
        !_host.hasRoom() ||
        !_host.micWanted()) {
      return;
    }
    if (!_host.switching().supportsInputSelection) {
      _host.log(
          'Microphone fallback skipped: this host cannot pick a microphone');
      return;
    }
    final generation = _generation;
    _runningGeneration = generation;
    try {
      await _tryAll(generation);
    } on Object catch (e) {
      if (!_live(generation)) return;
      _host.log('Microphone fallback failed: $e', level: LogLevel.warning);
      _fail();
    } finally {
      if (_runningGeneration == generation) _runningGeneration = null;
    }
  }

  Future<void> _tryAll(int generation) async {
    final switching = _host.switching();
    _tried.add(fallbackKey(switching.inputInUse));
    await _followSystemOutput();
    final candidates = fallbackCandidates(
      inputs: await switching.inputs(),
      inUseId: switching.inputInUse,
      tried: _tried,
    );
    for (final candidate in candidates) {
      if (!_live(generation)) return;
      _tried.add(fallbackKey(candidate?.id));
      if (await _tryOne(candidate, generation)) return;
    }
    if (!_live(generation)) return;
    _host.log(
      'No other microphone worked; leaving the microphone unavailable',
      level: LogLevel.warning,
    );
    _fail();
  }

  Future<void> _followSystemOutput() async {
    final switching = _host.switching();
    if (!switching.supportsOutputSelection) return;
    if (switching.followsSystemDefaultOutput) return;
    if (await _host.selectOutput(null)) {
      _host.log('Speaker moved back to the system default');
    }
  }

  /// True when the attempt ends the run: the call moved on, or the mic works or cannot be checked.
  Future<bool> _tryOne(AudioDevice? candidate, int generation) async {
    final target = candidate?.label ?? 'the system default';
    _host.log('Switching microphone to $target for this call only');
    if (!await _host.selectInput(candidate)) return false;
    if (!_live(generation)) return true;
    if (!await _host.restartCapture('fallback')) {
      _host.log('Could not reopen the microphone on $target',
          level: LogLevel.warning);
      return !_live(generation);
    }
    await Future<void>.delayed(_host.timing().fallbackSettle);
    if (!_live(generation)) return true;
    final sent = await _sentLevel();
    if (!_live(generation)) return true;
    if (sent != null && sent <= kInputFloorDb + 1) {
      _host.log('Microphone $target is silent too', level: LogLevel.warning);
      return false;
    }
    final shown = await _host.switching().inputDeviceInUse();
    if (!_live(generation)) return true;
    if (sent == null) {
      _host.log('Microphone fallback to $target could not be verified');
    } else {
      _host.log('Microphone fallback worked: $target');
      _host.watchdog().reset();
      _host.setStatus(MicStatus.ok);
    }
    await logDevices('fallback');
    if (_live(generation)) _setNotice(shown?.label ?? target);
    return true;
  }

  Future<double?> _sentLevel() async {
    try {
      return await _host.mic().senderLevelDb();
    } on Object {
      return null;
    }
  }

  void _fail() {
    _host.setStatus(MicStatus.unavailable);
    unawaited(_host.noteFailure(MicFailureReason.silent));
  }
}
