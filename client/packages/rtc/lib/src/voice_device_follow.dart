// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a call's microphone and speaker on the devices a person chose while
/// the platform's device list changes under it.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;

import 'audio_device_switching.dart';
import 'mic_port.dart';
import 'mic_recovery.dart';

/// What [VoiceDeviceFollow] needs from the microphone logic that owns it.
class VoiceDeviceFollowHost {
  const VoiceDeviceFollowHost({
    required this.room,
    required this.connected,
    required this.micWanted,
    required this.micStatus,
    required this.restartCapture,
    required this.logDevices,
    required this.logInputList,
    required this.log,
  });

  final lk.Room? Function() room;
  final bool Function() connected;
  final bool Function() micWanted;
  final MicStatus Function() micStatus;
  final Future<bool> Function(String reason) restartCapture;
  final Future<void> Function(String why) logDevices;
  final Future<void> Function() logInputList;
  final void Function(String message, {LogLevel level}) log;
}

/// Re-checks the chosen devices after a platform device change, once the
/// burst of change events has settled, and restarts a capture that moved.
class VoiceDeviceFollow {
  VoiceDeviceFollow(
    this._host, {
    required this.switching,
    required this.mic,
    required this.timing,
  });

  final VoiceDeviceFollowHost _host;
  final AudioDeviceSwitching switching;
  final MicPort mic;
  final MicRecoveryTiming timing;

  StreamSubscription<void>? _deviceChanges;
  StreamSubscription<void>? _playbackFollow;
  Timer? _debounce;
  bool _following = false;
  bool _changedMeanwhile = false;
  String? _lastChangeLine;
  String? _inputSignature;

  /// Starts watching; a second call while watching does nothing.
  void start() {
    _deviceChanges ??= switching.onChange.listen(_onChange);
    _playbackFollow ??= switching.followPlaybackStarts();
    unawaited(_rememberInputs());
  }

  void stop() {
    _debounce?.cancel();
    _debounce = null;
    _inputSignature = null;
    unawaited(_deviceChanges?.cancel());
    _deviceChanges = null;
    unawaited(_playbackFollow?.cancel());
    _playbackFollow = null;
  }

  Future<void> dispose() async {
    _debounce?.cancel();
    await _deviceChanges?.cancel();
    await _playbackFollow?.cancel();
  }

  void _onChange(void _) {
    _debounce?.cancel();
    _debounce = Timer(timing.deviceDebounce, () {
      _debounce = null;
      unawaited(_followOnce());
    });
  }

  /// A burst that lands while a re-check runs earns one more re-check, not one each.
  Future<void> _followOnce() async {
    if (_following) {
      _changedMeanwhile = true;
      return;
    }
    _following = true;
    try {
      do {
        _changedMeanwhile = false;
        await _follow();
      } while (_changedMeanwhile && _host.connected());
    } finally {
      _following = false;
    }
  }

  Future<void> _follow() async {
    if (!_host.connected()) return;
    var inputChanged = false;
    var inputDropped = false;
    try {
      // A join or leave makes the platform re-list, and one read can miss the chosen microphone.
      if (await switching.chosenInputMissing()) {
        await Future<void>.delayed(timing.deviceDebounce);
        if (!_host.connected()) return;
      }
      final reconciled = await switching.reconcilePreferences(_host.room());
      inputDropped = reconciled.inputDropped;
      inputChanged = inputDropped || reconciled.inputRestored;
      await switching.applyServerRouting();
      await switching.reapplyOutput(_host.room());
    } on Object catch (e) {
      _host.log(
        'Could not follow the audio device change: $e',
        level: LogLevel.warning,
      );
    }
    final defaultMoved = await _defaultInputMoved();
    final line = 'Audio devices changed; the chosen microphone is '
        '${_inputChangeWord(dropped: inputDropped, changed: inputChanged)}'
        '${defaultMoved ? ', and the system default moved' : ''}';
    if (line != _lastChangeLine) _host.log(line);
    _lastChangeLine = line;
    unawaited(_host.logDevices('device change'));
    if (!_host.micWanted()) return;
    if (inputChanged ||
        defaultMoved ||
        !mic.hasTrack ||
        _host.micStatus() != MicStatus.ok) {
      await _host.restartCapture('device change');
    }
  }

  Future<void> _rememberInputs() async {
    try {
      _inputSignature = await switching.inputSignature();
      unawaited(_host.logInputList());
    } on Object catch (e) {
      _host.log('Could not list microphones: $e', level: LogLevel.warning);
    }
  }

  String _inputChangeWord({required bool dropped, required bool changed}) {
    if (dropped) return 'gone';
    return changed ? 'back' : 'still there';
  }

  /// A capture that follows the system default has to move when that changes.
  Future<bool> _defaultInputMoved() async {
    final before = _inputSignature;
    await _rememberInputs();
    return switching.followsSystemDefaultInput &&
        before != null &&
        before != _inputSignature;
  }
}
