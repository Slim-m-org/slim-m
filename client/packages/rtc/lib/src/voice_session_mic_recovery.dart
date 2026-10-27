// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s microphone self-healing, a mixin for the reason
/// `voice_session_audio_devices.dart` gives.
///
/// Intent is what the user last asked for; the track is whatever the capture
/// stack managed to keep. Everything here moves the second toward the first.
mixin VoiceSessionMicRecovery {
  lk.Room? get _room;
  VoiceSessionState get _state;
  MicPort get _mic;
  Future<void> _applyInputGate();
  LocalAudioState get _audio;
  AudioDeviceSwitching get _audioSwitching;
  CaptureNoiseSuppression get _capture;
  MicFallback get _fallback;
  Future<void> _logAudioDevices(String why) => _fallback.logDevices(why);
  Future<void> _logInputList() => _fallback.logInputList();
  InputGateMonitor get _gate;
  late final void Function() _afterRestart;
  bool _micWanted = false;
  bool _watchDevices = false;
  MicStatus _micStatus = MicStatus.ok;
  late final MicRecoveryTiming _micTiming;
  late final MicRecovery _micRecovery;
  late final SilentMicWatchdog _micWatchdog;
  final _micStatuses = StreamController<MicStatus>.broadcast();
  final _micFailures = StreamController<MicFailureReason?>.broadcast();
  MicFailureReason? _micFailure;
  // ignore: prefer_final_fields
  OsMicBlockProbe _osMicBlocked = platformMicBlocked;
  StreamSubscription<void>? _micLost;
  StreamSubscription<InputGateReading>? _micLevels;
  StreamSubscription<void>? _deviceChanges;
  Timer? _deviceDebounce;
  bool _followingDeviceChange = false;
  bool _deviceChangedMeanwhile = false;
  String? _lastDeviceChangeLine;
  Timer? _senderPoll;
  String? _inputSignature;

  /// Whether the mic is healthy, being brought back, or given up on.
  MicStatus get micStatus => _micStatus;
  Stream<MicStatus> get micStatuses => _micStatuses.stream;

  /// Why the last attempt to open the microphone failed; null while it works.
  MicFailureReason? get micFailure => _micFailure;
  Stream<MicFailureReason?> get micFailures => _micFailures.stream;

  /// Records [reason] at once, then upgrades it when the OS says it is blocking us.
  Future<void> _noteMicFailure(MicFailureReason reason) async {
    _setMicFailure(reason);
    final refined = await refineMicFailure(reason, _osMicBlocked);
    if (refined != reason && _micFailure == reason) _setMicFailure(refined);
  }

  void _setMicFailure(MicFailureReason? next) {
    if (next == _micFailure) return;
    _micFailure = next;
    if (!_micFailures.isClosed) _micFailures.add(next);
  }

  void _initMicRecovery({
    required MicRecoveryTiming timing,
    required bool watchDevices,
    required Future<bool> Function() enable,
    required void Function() afterRestart,
  }) {
    _afterRestart = afterRestart;
    _micTiming = timing;
    _watchDevices = watchDevices;
    _micRecovery = MicRecovery(
      timing: timing,
      wanted: () => _micWanted && _state == VoiceSessionState.connected,
      enable: () async {
        // A track that failed mid-restart is still published but dead.
        if (_mic.hasTrack) await _mic.discard();
        return await enable() && _mic.open;
      },
      onStatus: _setMicStatus,
      log: _logMic,
    );
    _micWatchdog = SilentMicWatchdog(
      timing: timing,
      onSilent: () {
        unawaited(_onGateSilent());
      },
      onGaveUp: () {
        _logMic(
          'The microphone is still silent after every restart; asking the user to retry',
          level: LogLevel.warning,
        );
        unawaited(_logAudioDevices('gave up'));
        _setMicStatus(MicStatus.unavailable);
        unawaited(_noteMicFailure(MicFailureReason.silent));
        if (_fallback.enabled) unawaited(_fallback.run());
      },
      onRecovered: () {
        if (_micStatus == MicStatus.unavailable) _setMicStatus(MicStatus.ok);
      },
    );
    _micLost = _mic.lost.listen(
      (_) => _micRecovery.onLost('track ended or unpublished'),
    );
    _micLevels = _gate.readings.listen(_observeGateReading);
  }

  bool _gateStallLogged = false;

  /// The gate read the floor; the sender's own level decides whether that is
  /// a dead capture or a gate that is not processing, which a restart cannot cure.
  Future<void> _onGateSilent() async {
    double? sent;
    try {
      sent = await _mic.senderLevelDb();
    } on Object {
      sent = null;
    }
    if (sent != null && sent > kInputFloorDb + 1) {
      if (!_gateStallLogged) {
        _gateStallLogged = true;
        _logMic(
          'The input gate reads silence but the microphone is sending; '
          'reinstalling the gate instead of restarting the capture',
          level: LogLevel.warning,
        );
      }
      _micWatchdog.reset();
      unawaited(_applyInputGate());
      return;
    }
    _logMic(
      'Microphone is sending silence; restarting the capture',
      level: LogLevel.warning,
    );
    unawaited(_restartMicCapture('silent'));
  }

  /// Strong suppression turns a quiet room into near-silence, which read as a
  /// dead mic and restarted the capture every 30-60 s; it proves nothing either way.
  void _observeGateReading(InputGateReading reading) {
    if (reading.strongActive) return _micWatchdog.pause();
    _observeMicLevel(reading.levelDb);
  }

  void _observeMicLevel(double levelDb) => _micWatchdog.observe(
        levelDb,
        active:
            _micWanted && _mic.open && _state == VoiceSessionState.connected,
      );

  /// Hosts without the input gate read the sender's own stats instead.
  Future<void> _pollSenderLevel() async {
    if (_state != VoiceSessionState.connected || !_micWanted || !_mic.open) {
      return _micWatchdog.reset();
    }
    try {
      final level = await _mic.senderLevelDb();
      if (level != null) _observeMicLevel(level);
    } on Object catch (e) {
      _logMic('Could not read the sent audio level: $e', level: LogLevel.debug);
    }
  }

  Future<void> _disposeMicRecovery() async {
    _micRecovery.dispose();
    _deviceDebounce?.cancel();
    _senderPoll?.cancel();
    await _micLost?.cancel();
    await _micLevels?.cancel();
    await _deviceChanges?.cancel();
    await _micStatuses.close();
    await _micFailures.close();
    await _fallback.dispose();
  }

  void _logMic(String message, {LogLevel level = LogLevel.info}) =>
      _diag(message, level: level);

  /// Into the app's debug log when the app wired one, so a tester's export shows it.
  void _diag(String line, {LogLevel level = LogLevel.info}) =>
      (_audio.log ?? _appLogVoice)(line, level: level);

  static void _appLogVoice(String line, {LogLevel level = LogLevel.info}) =>
      AppLog.at(level, LogTag.voice, line);

  void _setMicStatus(MicStatus next) {
    if (next == _micStatus) return;
    _micStatus = next;
    if (next == MicStatus.ok) _setMicFailure(null);
    if (!_micStatuses.isClosed) _micStatuses.add(next);
  }

  /// Follows the call: device changes are watched only while it is up.
  void _syncMicWatch(VoiceSessionState state) {
    if (state == VoiceSessionState.connected) {
      unawaited(_logAudioDevices('join'));
      unawaited(_logInputList());
      if (_watchDevices) {
        _deviceChanges ??= _audioSwitching.onChange.listen(_onDeviceChange);
        unawaited(_rememberInputs());
      }
      if (!_gate.supported) {
        _senderPoll ??= Timer.periodic(
          _micTiming.senderPoll,
          (_) => unawaited(_pollSenderLevel()),
        );
      }
      return;
    }
    _stopMicWatch();
  }

  void _stopMicWatch() {
    _micWanted = false;
    _deviceDebounce?.cancel();
    _deviceDebounce = null;
    _senderPoll?.cancel();
    _senderPoll = null;
    _inputSignature = null;
    _fallback.reset();
    unawaited(_deviceChanges?.cancel());
    _deviceChanges = null;
    _micRecovery.reset();
    _micWatchdog.reset();
    _setMicFailure(null);
  }

  /// A mic that would not open at join (permission, a device that was not ready)
  /// is retried like a lost one, so the person sees it and is not left unheard.
  void _retryMicAfterJoin() {
    _micWanted = true;
    _micRecovery.onLost('could not open at join');
  }

  void _onDeviceChange(void _) {
    _deviceDebounce?.cancel();
    _deviceDebounce = Timer(_micTiming.deviceDebounce, () {
      _deviceDebounce = null;
      unawaited(_followDeviceChangeOnce());
    });
  }

  /// A burst that lands while a re-check runs earns one more re-check, not one each.
  Future<void> _followDeviceChangeOnce() async {
    if (_followingDeviceChange) {
      _deviceChangedMeanwhile = true;
      return;
    }
    _followingDeviceChange = true;
    try {
      do {
        _deviceChangedMeanwhile = false;
        await _followDeviceChange();
      } while (
          _deviceChangedMeanwhile && _state == VoiceSessionState.connected);
    } finally {
      _followingDeviceChange = false;
    }
  }

  Future<void> _followDeviceChange() async {
    if (_state != VoiceSessionState.connected) return;
    var inputChanged = false;
    var inputDropped = false;
    try {
      // A join or leave makes the platform re-list, and one read can miss the chosen microphone.
      if (await _audioSwitching.chosenInputMissing()) {
        await Future<void>.delayed(_micTiming.deviceDebounce);
        if (_state != VoiceSessionState.connected) return;
      }
      final reconciled = await _audioSwitching.reconcilePreferences(_room);
      inputDropped = reconciled.inputDropped;
      inputChanged = inputDropped || reconciled.inputRestored;
      await _audioSwitching.applyServerRouting();
      await _audioSwitching.reapplyOutput(_room);
    } on Object catch (e) {
      _logMic(
        'Could not follow the audio device change: $e',
        level: LogLevel.warning,
      );
    }
    final defaultMoved = await _defaultInputMoved();
    final line = 'Audio devices changed; the chosen microphone is '
        '${_inputChangeWord(dropped: inputDropped, changed: inputChanged)}'
        '${defaultMoved ? ', and the system default moved' : ''}';
    if (line != _lastDeviceChangeLine) _logMic(line);
    _lastDeviceChangeLine = line;
    unawaited(_logAudioDevices('device change'));
    if (!_micWanted) return;
    if (inputChanged ||
        defaultMoved ||
        !_mic.hasTrack ||
        _micStatus != MicStatus.ok) {
      await _restartMicCapture('device change');
    }
  }

  Future<void> _rememberInputs() async {
    try {
      _inputSignature = await _audioSwitching.inputSignature();
      unawaited(_logInputList());
    } on Object catch (e) {
      _logMic('Could not list microphones: $e', level: LogLevel.warning);
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
    return _audioSwitching.followsSystemDefaultInput &&
        before != null &&
        before != _inputSignature;
  }

  /// Reopens the capture where the user wants the mic open, republishing it
  /// when there is no track or the reopen fails.
  Future<bool> _restartMicCapture(String reason) async {
    if (_room == null || !_micWanted) return false;
    unawaited(_logAudioDevices('restart: $reason'));
    if (!_mic.hasTrack) return _micRecovery.recoverNow(reason);
    try {
      await _mic.restart(_currentCaptureOptions());
      _afterRestart();
      _logMic('Microphone capture restarted ($reason)');
      if (_micStatus == MicStatus.unavailable) _setMicStatus(MicStatus.ok);
      return true;
    } on Object catch (e) {
      _logMic(
        'Could not restart the microphone capture ($reason): $e',
        level: LogLevel.warning,
      );
      return _micRecovery.recoverNow('$reason, restart failed');
    }
  }

  Future<void> _restartCapture({required bool webrtcNoiseSuppression}) async {
    try {
      await _mic.restart(
        _audioSwitching.captureOptions(
          noiseSuppression: webrtcNoiseSuppression,
        ),
      );
    } on Object {
      // The failed restart stopped the old capture first; put a live one back.
      await _revive(webrtcNoiseSuppression: webrtcNoiseSuppression);
      rethrow;
    }
    _afterRestart();
  }

  Future<void> _revive({required bool webrtcNoiseSuppression}) async {
    _capture.fallBack();
    if (!_micWanted) {
      if (_mic.hasTrack) await _mic.discard();
      return;
    }
    try {
      if (!webrtcNoiseSuppression) {
        await _mic.restart(_currentCaptureOptions());
        _capture.opened(webrtcNoiseSuppression: true);
        _logMic(
          'voice-ns: fallback to standard: strong restart failed, mic reopened',
          level: LogLevel.warning,
        );
        return;
      }
    } on Object catch (e) {
      _logMic(
        'Could not reopen the microphone after a failed restart: $e',
        level: LogLevel.warning,
      );
    }
    await _micRecovery.recoverNow('restart failed');
  }

  lk.AudioCaptureOptions _currentCaptureOptions() =>
      _audioSwitching.captureOptions(
        noiseSuppression: _capture.webrtcNoiseSuppression,
      );

  /// Force-restarts the capture, bypassing the same-device no-op a picker
  /// selection has; the tap on a mic button that says it is unavailable. A
  /// muted mic gets its track dropped, so the next unmute opens a fresh one.
  Future<bool> resetMicrophone() async {
    if (_room == null) return false;
    _logMic('Microphone reset requested');
    _micWatchdog.reset();
    if (!_micWanted) {
      if (_mic.hasTrack) await _mic.discard();
      return true;
    }
    return _restartMicCapture('reset');
  }
}
