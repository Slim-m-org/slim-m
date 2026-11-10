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
  LocalAudioState get _audio;
  AudioDeviceSwitching get _audioSwitching;
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
  late final MicStallWatchdog _micWatchdog;
  final _micStatuses = StreamController<MicStatus>.broadcast();
  final _micFailures = StreamController<MicFailureReason?>.broadcast();
  MicFailureReason? _micFailure;
  // ignore: prefer_final_fields
  OsMicBlockProbe _osMicBlocked = platformMicBlocked;
  StreamSubscription<void>? _micLost;
  StreamSubscription<InputGateReading>? _micLevels;
  StreamSubscription<void>? _deviceChanges;
  StreamSubscription<void>? _playbackFollow;
  Timer? _deviceDebounce;
  bool _followingDeviceChange = false;
  bool _deviceChangedMeanwhile = false;
  String? _lastDeviceChangeLine;
  Timer? _senderPoll;
  Timer? _captureProbe;
  final _captureProgress = CaptureProgress();
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
        _forgetCaptureProgress();
        return await enable() && _mic.open;
      },
      onStatus: _onRecoveryStatus,
      log: _logMic,
    );
    _micWatchdog = MicStallWatchdog(
      timing: timing,
      onStalled: () {
        _logMic(
          'The microphone capture stopped moving; restarting it',
          level: LogLevel.warning,
        );
        unawaited(_restartMicCapture('capture stalled'));
      },
      onGaveUp: () {
        _logMic(
          'The microphone capture is still stalled after every restart; asking the user to retry',
          level: LogLevel.warning,
        );
        unawaited(_logAudioDevices('gave up'));
        _setMicStatus(MicStatus.unavailable);
        unawaited(_noteMicFailure(MicFailureReason.stalled));
      },
      onRecovered: () {
        if (_micStatus == MicStatus.unavailable) _setMicStatus(MicStatus.ok);
      },
      onQuiet: () => _logMic(
        'The microphone has read digital silence for a while but its capture '
        'is running; leaving it alone',
      ),
    );
    _micLost = _mic.lost.listen(
      (_) => _micRecovery.onLost('track ended or unpublished'),
    );
    _micLevels = _gate.readings.listen(_observeGateReading);
  }

  /// Strong suppression turns a quiet room into near-silence, so its readings say nothing about the mic.
  void _observeGateReading(InputGateReading reading) {
    if (!reading.strongActive) _observeMicLevel(reading.levelDb);
  }

  void _observeMicLevel(double levelDb) => _micWatchdog.observe(
        levelDb,
        active:
            _micWanted && _mic.open && _state == VoiceSessionState.connected,
      );

  /// Hosts without the input gate read the sender's own stats for the quiet note.
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

  /// A new capture counts from its own first reading, and gets a grace to start.
  void _forgetCaptureProgress() {
    _captureProgress.reset();
  }

  /// Reads the media source's sample counter on its own clock: the only sign
  /// of life, whatever the level says. A host that reports none is never restarted.
  Future<void> _probeCapture() async {
    final active =
        _state == VoiceSessionState.connected && _micWanted && _mic.open;
    if (!active) {
      _forgetCaptureProgress();
      return _micWatchdog.observeProgress(advancing: null, active: false);
    }
    double? seconds;
    try {
      seconds = await _mic.capturedSeconds();
    } on Object catch (e) {
      _logMic('Could not read the capture counter: $e', level: LogLevel.debug);
    }
    if (_state != VoiceSessionState.connected || !_micWanted || !_mic.open) {
      return;
    }
    _micWatchdog.observeProgress(
      advancing: _captureProgress.advanced(seconds),
      active: true,
    );
  }

  Future<void> _disposeMicRecovery() async {
    _micRecovery.dispose();
    _deviceDebounce?.cancel();
    _senderPoll?.cancel();
    _captureProbe?.cancel();
    await _micLost?.cancel();
    await _micLevels?.cancel();
    await _deviceChanges?.cancel();
    await _playbackFollow?.cancel();
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

  /// Recovery that cannot reopen the mic hands over to the device fallback only
  /// when the device in use is gone from the list, never because it is quiet.
  void _onRecoveryStatus(MicStatus next) {
    _setMicStatus(next);
    if (next == MicStatus.unavailable && _fallback.enabled) {
      unawaited(_fallbackIfDeviceGone());
    }
  }

  Future<void> _fallbackIfDeviceGone() async {
    try {
      if (!await _audioSwitching.chosenInputMissing()) return;
    } on Object {
      return;
    }
    _logMic('The microphone in use is gone; trying another one');
    await _fallback.run();
  }

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
        _playbackFollow ??= _audioSwitching.followPlaybackStarts();
        unawaited(_rememberInputs());
      }
      if (!_gate.supported) {
        _senderPoll ??= Timer.periodic(
          _micTiming.senderPoll,
          (_) => unawaited(_pollSenderLevel()),
        );
      }
      _captureProbe ??= Timer.periodic(
        _micTiming.captureProbe,
        (_) => unawaited(_probeCapture()),
      );
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
    _captureProbe?.cancel();
    _captureProbe = null;
    _forgetCaptureProgress();
    _inputSignature = null;
    _fallback.reset();
    unawaited(_deviceChanges?.cancel());
    _deviceChanges = null;
    unawaited(_playbackFollow?.cancel());
    _playbackFollow = null;
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
      await _mic.restart(_audioSwitching.captureOptions());
      _forgetCaptureProgress();
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
