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
  CaptureNoiseSuppression get _capture;
  InputGateMonitor get _gate;
  late final void Function() _afterRestart;
  bool _micWanted = false;
  bool _watchDevices = false;
  MicStatus _micStatus = MicStatus.ok;
  late final MicRecoveryTiming _micTiming;
  late final MicRecovery _micRecovery;
  late final SilentMicWatchdog _micWatchdog;
  final _micStatuses = StreamController<MicStatus>.broadcast();
  StreamSubscription<void>? _micLost;
  StreamSubscription<InputGateReading>? _micLevels;
  StreamSubscription<void>? _deviceChanges;
  Timer? _deviceDebounce;
  Timer? _senderPoll;
  String? _inputSignature;

  /// Whether the mic is healthy, being brought back, or given up on.
  MicStatus get micStatus => _micStatus;
  Stream<MicStatus> get micStatuses => _micStatuses.stream;

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
        _logMic('mic reads digital silence, restarting capture');
        unawaited(_restartMicCapture('silent'));
      },
      onGaveUp: () {
        _logMic('mic still reads digital silence after every restart');
        _setMicStatus(MicStatus.unavailable);
      },
      onRecovered: () {
        if (_micStatus == MicStatus.unavailable) _setMicStatus(MicStatus.ok);
      },
    );
    _micLost = _mic.lost.listen(
      (_) => _micRecovery.onLost('track ended or unpublished'),
    );
    _micLevels = _gate.readings.listen((r) => _observeMicLevel(r.levelDb));
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
      _logMic('sender level unavailable: $e');
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
  }

  void _logMic(String message) => _diag('voice: $message');

  /// Into the app's debug log when the app wired one, so a tester's export shows it.
  void _diag(String line) =>
      (_audio.log ?? (l) => AppLog.info(LogTag.voice, l))(line);

  void _setMicStatus(MicStatus next) {
    if (next == _micStatus) return;
    _micStatus = next;
    if (!_micStatuses.isClosed) _micStatuses.add(next);
  }

  /// Follows the call: device changes are watched only while it is up.
  void _syncMicWatch(VoiceSessionState state) {
    if (state == VoiceSessionState.connected) {
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
    unawaited(_deviceChanges?.cancel());
    _deviceChanges = null;
    _micRecovery.reset();
    _micWatchdog.reset();
  }

  void _onDeviceChange(void _) {
    _deviceDebounce?.cancel();
    _deviceDebounce = Timer(_micTiming.deviceDebounce, () {
      _deviceDebounce = null;
      unawaited(_followDeviceChange());
    });
  }

  Future<void> _followDeviceChange() async {
    if (_state != VoiceSessionState.connected) return;
    var inputDropped = false;
    try {
      inputDropped = await _audioSwitching.forgetUnpluggedPreferences();
      await _audioSwitching.applyServerRouting();
    } on Object catch (e) {
      _logMic('device change follow failed: $e');
    }
    final defaultMoved = await _defaultInputMoved();
    _logMic('audio devices changed, chosen microphone gone: $inputDropped, '
        'default moved: $defaultMoved');
    if (!_micWanted) return;
    if (inputDropped ||
        defaultMoved ||
        !_mic.hasTrack ||
        _micStatus != MicStatus.ok) {
      await _restartMicCapture('device change');
    }
  }

  Future<void> _rememberInputs() async {
    try {
      _inputSignature = await _audioSwitching.inputSignature();
    } on Object catch (e) {
      _logMic('could not list microphones: $e');
    }
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
    if (!_mic.hasTrack) return _micRecovery.recoverNow(reason);
    try {
      await _mic.restart(_currentCaptureOptions());
      _afterRestart();
      _logMic('capture restarted ($reason)');
      if (_micStatus == MicStatus.unavailable) _setMicStatus(MicStatus.ok);
      return true;
    } on Object catch (e) {
      _logMic('capture restart failed ($reason): $e');
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
        _logMic('strong restart failed, reopened with libwebrtc suppression');
        return;
      }
    } on Object catch (e) {
      _logMic('reopen after failed restart also failed: $e');
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
    _logMic('reset microphone requested');
    _micWatchdog.reset();
    if (!_micWanted) {
      if (_mic.hasTrack) await _mic.discard();
      return true;
    }
    return _restartMicCapture('reset');
  }
}
