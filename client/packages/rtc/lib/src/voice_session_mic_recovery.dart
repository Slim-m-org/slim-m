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
    );
    _micLost = _mic.lost.listen(
      (_) => _micRecovery.onLost('track ended or unpublished'),
    );
    _micLevels = _gate.readings.listen(
      (r) => _micWatchdog.observe(
        r.levelDb,
        active:
            _micWanted && _mic.open && _state == VoiceSessionState.connected,
      ),
    );
  }

  Future<void> _disposeMicRecovery() async {
    _micRecovery.dispose();
    _deviceDebounce?.cancel();
    await _micLost?.cancel();
    await _micLevels?.cancel();
    await _deviceChanges?.cancel();
    await _micStatuses.close();
  }

  void _logMic(String message) => debugPrint('voice: $message');

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
      }
      return;
    }
    _stopMicWatch();
  }

  void _stopMicWatch() {
    _micWanted = false;
    _deviceDebounce?.cancel();
    _deviceDebounce = null;
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
    _logMic('audio devices changed, chosen microphone gone: $inputDropped');
    if (!_micWanted) return;
    if (inputDropped || !_mic.hasTrack || _micStatus != MicStatus.ok) {
      await _restartMicCapture('device change');
    }
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
  /// selection has. A muted mic gets its track dropped, so the next unmute
  /// opens a fresh one.
  Future<bool> resetMicrophone() async {
    if (_room == null) return false;
    _logMic('reset microphone requested');
    if (!_micWanted) {
      if (_mic.hasTrack) await _mic.discard();
      return true;
    }
    return _restartMicCapture('reset');
  }
}
