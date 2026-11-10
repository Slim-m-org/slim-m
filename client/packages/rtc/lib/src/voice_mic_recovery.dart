// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice session's microphone intent and its self-healing.
///
/// Intent is what the user last asked for; the track is whatever the capture
/// stack managed to keep. Everything here moves the second toward the first.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel, LogTag, reportFailure;

import 'audio_device_switching.dart';
import 'input_gate.dart';
import 'mic_failure.dart';
import 'mic_port.dart';
import 'mic_recovery.dart';
import 'mic_release.dart';
import 'voice_device_follow.dart';
import 'voice_models.dart';
import 'voice_session_mic_fallback.dart';

/// What [VoiceMicRecovery] needs from the session that owns it.
class VoiceMicRecoveryHost {
  const VoiceMicRecoveryHost({
    required this.room,
    required this.state,
    required this.noteError,
    required this.refresh,
    required this.diag,
    required this.openCaptureOptions,
    required this.forgetUnplugged,
    required this.followPreferred,
    required this.selectInput,
    required this.selectOutput,
    required this.micPublished,
  });

  final lk.Room? Function() room;
  final VoiceSessionState Function() state;
  final void Function(Object error) noteError;
  final void Function() refresh;
  final void Function(String line, {LogLevel level}) diag;
  final lk.AudioCaptureOptions Function({required bool reopen})
      openCaptureOptions;
  final Future<void> Function() forgetUnplugged;
  final void Function() followPreferred;

  /// Both move only the live device, never the remembered choice.
  final Future<bool> Function(AudioDevice? device) selectInput;
  final Future<bool> Function(AudioDevice? device) selectOutput;
  final void Function() micPublished;
}

/// Owns whether the microphone is wanted and brings the capture back when it
/// is lost, stalls, or the device it was on goes away.
class VoiceMicRecovery {
  VoiceMicRecovery(
    this._host, {
    required this.mic,
    required this.gate,
    required this.switching,
    required this.release,
    required this.timing,
    required this.watchDevices,
    OsMicBlockProbe? osMicBlocked,
  }) : _osMicBlocked = osMicBlocked ?? platformMicBlocked {
    fallback = MicFallback(
      MicFallbackHost(
        switching: () => switching,
        hasRoom: () => _host.room() != null,
        micWanted: () => micWanted,
        mic: () => mic,
        timing: () => timing,
        watchdog: () => _watchdog,
        log: _log,
        setStatus: _setStatus,
        noteFailure: noteFailure,
        restartCapture: restartCapture,
        selectInput: _host.selectInput,
        selectOutput: _host.selectOutput,
      ),
    );
    _follow = VoiceDeviceFollow(
      VoiceDeviceFollowHost(
        room: _host.room,
        connected: _connected,
        micWanted: () => micWanted,
        micStatus: () => _status,
        restartCapture: restartCapture,
        logDevices: fallback.logDevices,
        logInputList: fallback.logInputList,
        log: _log,
      ),
      switching: switching,
      mic: mic,
      timing: timing,
    );
    _recovery = MicRecovery(
      timing: timing,
      wanted: () => micWanted && _connected(),
      enable: () async {
        // A track that failed mid-restart is still published but dead.
        if (mic.hasTrack) await mic.discard();
        _captureProgress.reset();
        return await setEnabled(true) && mic.open;
      },
      onStatus: _onRecoveryStatus,
      log: _log,
    );
    _watchdog = MicStallWatchdog(
      timing: timing,
      onStalled: () {
        _log(
          'The microphone capture stopped moving; restarting it',
          level: LogLevel.warning,
        );
        unawaited(restartCapture('capture stalled'));
      },
      onGaveUp: () {
        _log(
          'The microphone capture is still stalled after every restart; asking the user to retry',
          level: LogLevel.warning,
        );
        unawaited(fallback.logDevices('gave up'));
        _setStatus(MicStatus.unavailable);
        unawaited(noteFailure(MicFailureReason.stalled));
      },
      onRecovered: () {
        if (_status == MicStatus.unavailable) _setStatus(MicStatus.ok);
      },
      onQuiet: () => _log(
        'The microphone has read digital silence for a while but its capture '
        'is running; leaving it alone',
      ),
    );
    _micLost = mic.lost.listen(
      (_) => _recovery.onLost('track ended or unpublished'),
    );
    _micLevels = gate.readings.listen(_observeGateReading);
  }

  final VoiceMicRecoveryHost _host;
  final MicPort mic;
  final InputGateMonitor gate;
  final AudioDeviceSwitching switching;
  final MicRelease release;
  final MicRecoveryTiming timing;
  final bool watchDevices;
  final OsMicBlockProbe _osMicBlocked;

  late final MicFallback fallback;
  late final VoiceDeviceFollow _follow;
  late final MicRecovery _recovery;
  late final MicStallWatchdog _watchdog;

  bool _wanted = false;

  /// What the user last asked for: true while they want to be heard.
  bool get micWanted => _wanted;

  MicStatus _status = MicStatus.ok;
  final _statuses = StreamController<MicStatus>.broadcast();
  final _failures = StreamController<MicFailureReason?>.broadcast();
  MicFailureReason? _failure;
  late final StreamSubscription<void> _micLost;
  late final StreamSubscription<InputGateReading> _micLevels;
  Timer? _senderPoll;
  Timer? _captureProbe;
  final _captureProgress = CaptureProgress();

  /// Whether the mic is healthy, being brought back, or given up on.
  MicStatus get status => _status;
  Stream<MicStatus> get statuses => _statuses.stream;

  /// Why the last attempt to open the microphone failed; null while it works.
  MicFailureReason? get failure => _failure;
  Stream<MicFailureReason?> get failures => _failures.stream;

  bool _connected() => _host.state() == VoiceSessionState.connected;

  void _log(String message, {LogLevel level = LogLevel.info}) =>
      _host.diag(message, level: level);

  /// Records [reason] at once, then upgrades it when the OS says it is blocking us.
  Future<void> noteFailure(MicFailureReason reason) async {
    _setFailure(reason);
    final refined = await refineMicFailure(reason, _osMicBlocked);
    if (refined != reason && _failure == reason) _setFailure(refined);
  }

  void _setFailure(MicFailureReason? next) {
    if (next == _failure) return;
    _failure = next;
    if (!_failures.isClosed) _failures.add(next);
  }

  void _setStatus(MicStatus next) {
    if (next == _status) return;
    _status = next;
    if (next == MicStatus.ok) _setFailure(null);
    if (!_statuses.isClosed) _statuses.add(next);
  }

  /// Mutes or unmutes the local microphone; returns whether it ended in the
  /// requested state, since a token without SPEAK or a denied OS permission
  /// mean no and the UI must show what happened.
  Future<bool> setEnabled(bool enabled) async {
    if (_host.room() == null) return false;
    final intent = _wanted;
    _wanted = enabled;
    // A chosen microphone that came back since the last open is used again, not the default.
    if (enabled && switching.chosenInput != null) {
      await _host.forgetUnplugged();
    }
    try {
      final reopen = enabled && release.onUnmuting();
      final opened = Stopwatch()..start();
      await mic.setEnabled(enabled, _host.openCaptureOptions(reopen: reopen));
      if (reopen) {
        _log('Reopened the microphone in ${opened.elapsedMilliseconds} ms');
      }
      _noteSet(enabled);
      _host.refresh();
      if (enabled) _host.followPreferred();
      _setFailure(null);
      _recovery.reset();
      return true;
    } catch (e, stack) {
      reportFailure(LogTag.voice, 'turn the microphone on or off', e, stack);
      _wanted = intent;
      if (enabled && mic.hasTrack) release.onMuted();
      if (enabled) unawaited(noteFailure(classifyMicFailure(e)));
      _host.noteError(e);
      _host.refresh();
      return false;
    }
  }

  void _noteSet(bool enabled) {
    enabled ? release.reopened() : release.onMuted();
    if (enabled) _host.micPublished();
  }

  /// Strong suppression turns a quiet room into near-silence, so its readings say nothing about the mic.
  void _observeGateReading(InputGateReading reading) {
    if (!reading.strongActive) _observeLevel(reading.levelDb);
  }

  void _observeLevel(double levelDb) => _watchdog.observe(
        levelDb,
        active: micWanted && mic.open && _connected(),
      );

  /// Hosts without the input gate read the sender's own stats for the quiet note.
  Future<void> _pollSenderLevel() async {
    if (!_connected() || !micWanted || !mic.open) {
      return _watchdog.reset();
    }
    try {
      final level = await mic.senderLevelDb();
      if (level != null) _observeLevel(level);
    } on Object catch (e) {
      _log('Could not read the sent audio level: $e', level: LogLevel.debug);
    }
  }

  /// Reads the media source's sample counter on its own clock: the only sign
  /// of life, whatever the level says. A host that reports none is never restarted.
  Future<void> _probeCapture() async {
    final active = _connected() && micWanted && mic.open;
    if (!active) {
      _captureProgress.reset();
      return _watchdog.observeProgress(advancing: null, active: false);
    }
    double? seconds;
    try {
      seconds = await mic.capturedSeconds();
    } on Object catch (e) {
      _log('Could not read the capture counter: $e', level: LogLevel.debug);
    }
    if (!_connected() || !micWanted || !mic.open) return;
    _watchdog.observeProgress(
      advancing: _captureProgress.advanced(seconds),
      active: true,
    );
  }

  /// Recovery that cannot reopen the mic hands over to the device fallback only
  /// when the device in use is gone from the list, never because it is quiet.
  void _onRecoveryStatus(MicStatus next) {
    _setStatus(next);
    if (next == MicStatus.unavailable && fallback.enabled) {
      unawaited(_fallbackIfDeviceGone());
    }
  }

  Future<void> _fallbackIfDeviceGone() async {
    try {
      if (!await switching.chosenInputMissing()) return;
    } on Object {
      return;
    }
    _log('The microphone in use is gone; trying another one');
    await fallback.run();
  }

  /// Follows the call: device changes are watched only while it is up.
  void syncWatch(VoiceSessionState state) {
    if (state == VoiceSessionState.connected) {
      unawaited(fallback.logDevices('join'));
      unawaited(fallback.logInputList());
      if (watchDevices) _follow.start();
      if (!gate.supported) {
        _senderPoll ??= Timer.periodic(
          timing.senderPoll,
          (_) => unawaited(_pollSenderLevel()),
        );
      }
      _captureProbe ??= Timer.periodic(
        timing.captureProbe,
        (_) => unawaited(_probeCapture()),
      );
      return;
    }
    stopWatch();
  }

  void stopWatch() {
    _wanted = false;
    _senderPoll?.cancel();
    _senderPoll = null;
    _captureProbe?.cancel();
    _captureProbe = null;
    _captureProgress.reset();
    fallback.reset();
    _follow.stop();
    _recovery.reset();
    _watchdog.reset();
    _setFailure(null);
  }

  /// A mic that would not open at join (permission, a device that was not ready)
  /// is retried like a lost one, so the person sees it and is not left unheard.
  void retryAfterJoin() {
    _wanted = true;
    _recovery.onLost('could not open at join');
  }

  /// Reopens the capture where the user wants the mic open, republishing it
  /// when there is no track or the reopen fails.
  Future<bool> restartCapture(String reason) async {
    if (_host.room() == null || !micWanted) return false;
    unawaited(fallback.logDevices('restart: $reason'));
    if (!mic.hasTrack) return _recovery.recoverNow(reason);
    try {
      await mic.restart(switching.captureOptions());
      _captureProgress.reset();
      _host.followPreferred();
      _log('Microphone capture restarted ($reason)');
      if (_status == MicStatus.unavailable) _setStatus(MicStatus.ok);
      return true;
    } on Object catch (e) {
      _log(
        'Could not restart the microphone capture ($reason): $e',
        level: LogLevel.warning,
      );
      return _recovery.recoverNow('$reason, restart failed');
    }
  }

  /// Force-restarts the capture, bypassing the same-device no-op a picker
  /// selection has; the tap on a mic button that says it is unavailable. A
  /// muted mic gets its track dropped, so the next unmute opens a fresh one.
  Future<bool> reset() async {
    if (_host.room() == null) return false;
    _log('Microphone reset requested');
    _watchdog.reset();
    if (!micWanted) {
      if (mic.hasTrack) await mic.discard();
      return true;
    }
    return restartCapture('reset');
  }

  Future<void> dispose() async {
    _recovery.dispose();
    _senderPoll?.cancel();
    _captureProbe?.cancel();
    await _micLost.cancel();
    await _micLevels.cancel();
    await _follow.dispose();
    await _statuses.close();
    await _failures.close();
    await fallback.dispose();
  }
}
