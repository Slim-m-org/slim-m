// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice session's microphone intent and its self-healing.
///
/// Intent is what the user last asked for; the track is whatever the capture
/// stack managed to keep. Everything here moves the second toward the first.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart'
    show AppLog, LogLevel, LogTag, reportFailure;

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
    required this.roomConnected,
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
    required this.reconnecting,
  });

  final lk.Room? Function() room;
  final bool Function() roomConnected;
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

  /// Whether livekit is rebuilding the connection, which republishes the microphone itself.
  final bool Function() reconnecting;
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
        // Missing at the probe but republished by livekit since: that track is the good outcome.
        if (_lostUnpublished && mic.hasTrack && mic.open) return true;
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
    _micLost = mic.lost.listen((_) {
      _lostUnpublished = false;
      _recovery.onLost('track ended or unpublished');
    });
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

  /// The [setEnabled] calls in flight, which publish on their own.
  int _setting = 0;

  /// Counts [setEnabled] calls, so one can tell a later ask overtook it.
  int _asks = 0;
  int _unpublishedProbes = 0;

  /// The last loss was only a missing publication, so a track that has since
  /// appeared is livekit's own republish rather than a dead one to replace.
  bool _lostUnpublished = false;

  /// Runs from the first probe that saw the full restart under way.
  Stopwatch? _restartSeen;

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

  bool? _askedWhileConnecting;

  /// Whether the join opens the microphone: a mute or unmute asked while it
  /// was connecting wins over [asked], what the join was started with.
  bool wantedAtJoin(bool asked) => _askedWhileConnecting ?? asked;

  /// Mutes or unmutes the local microphone; returns whether it ended in the
  /// requested state, since a token without SPEAK or a denied OS permission
  /// mean no and the UI must show what happened. The last ask wins: one
  /// overtaken before it reached the microphone only says whether it agrees.
  Future<bool> setEnabled(bool enabled) async {
    if (_host.room() == null) return false;
    // Nothing can be published before the connect, so the join applies this once it has.
    if (_host.state() == VoiceSessionState.connecting) {
      _askedWhileConnecting = enabled;
      if (!_host.roomConnected()) {
        _asks++;
        _wanted = enabled;
        return true;
      }
    }
    final ask = ++_asks;
    final intent = _wanted;
    _wanted = enabled;
    // A chosen microphone that came back since the last open is used again, not the default.
    if (enabled && switching.chosenInput != null) {
      await _host.forgetUnplugged();
      // The later ask already reached the microphone, which applies asks in order.
      if (ask != _asks) return _wanted == enabled;
    }
    _setting++;
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
      // A later ask stands; putting this one's old intent back would undo it.
      if (ask == _asks) _wanted = intent;
      if (enabled && mic.hasTrack) release.onMuted();
      if (enabled) unawaited(noteFailure(classifyMicFailure(e)));
      _host.noteError(e);
      _host.refresh();
      return false;
    } finally {
      _setting--;
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
    _watchUnpublished();
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

  /// Brings back a wanted microphone with no publication; a full restart first
  /// gets [MicRecoveryTiming.restartRepublish] to republish it itself.
  void _watchUnpublished() {
    final holding = _awaitingRestartRepublish();
    final missing = !mic.hasTrack &&
        _setting == 0 &&
        !_recovery.busy &&
        !holding &&
        _status != MicStatus.unavailable;
    if (!missing) {
      _unpublishedProbes = 0;
      return;
    }
    // Two probes in a row, so the gap inside a healthy republish is not a loss.
    if (++_unpublishedProbes < 2) return;
    _unpublishedProbes = 0;
    _lostUnpublished = true;
    _recovery.onLost('wanted but not published');
  }

  bool _awaitingRestartRepublish() {
    if (!_host.reconnecting()) {
      _restartSeen = null;
      return false;
    }
    final seen = _restartSeen ??= Stopwatch()..start();
    return seen.elapsed < timing.restartRepublish;
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
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Could not check whether the microphone in use is gone',
        error,
        stack,
      );
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
    _askedWhileConnecting = null;
    _senderPoll?.cancel();
    _senderPoll = null;
    _captureProbe?.cancel();
    _captureProbe = null;
    _captureProgress.reset();
    _unpublishedProbes = 0;
    _lostUnpublished = false;
    _restartSeen = null;
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
    _lostUnpublished = false;
    _recovery.onLost('could not open at join');
  }

  /// Reopens the capture where the user wants the mic open, republishing it
  /// when there is no track or the reopen fails.
  Future<bool> restartCapture(String reason) async {
    if (_host.room() == null || !micWanted) return false;
    unawaited(fallback.logDevices('restart: $reason'));
    _lostUnpublished = false;
    if (!mic.hasTrack) return _recovery.recoverNow(reason);
    try {
      await mic.restart(switching.captureOptions());
      // The reopened capture is live, and a mute that landed meanwhile already muted the publication.
      if (!micWanted) {
        _log('Muted during a capture restart');
        await release.releaseReopened();
        return true;
      }
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
