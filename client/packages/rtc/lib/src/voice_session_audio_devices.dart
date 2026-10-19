// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s microphone and speaker picker: `audio_devices.dart` and
/// `audio_device_switching.dart`'s own shape mixed in here, rather than an
/// extension like `voice_session_tracks.dart`'s own private plumbing.
///
/// This surface is public - `selectAudioInputDevice` and its neighbours -
/// and only a mixin's members count as real members of the class an
/// `implements VoiceSession` fake checks against; an extension's do not,
/// which is `voice_session_tracks.dart`'s own reason for keeping every
/// *public* method declared directly on [VoiceSession] itself. A mixin is
/// how this stays public without growing that file past its own 500-line
/// ceiling.
///
/// Reaches [VoiceSession]'s own `_room` and `_lastError` as abstract
/// requirements rather than an `on VoiceSession` clause: `VoiceSession`'s
/// own declaration is what mixes this in, so constraining `on` the very
/// class being defined is circular and Dart rejects it.
/// `VoiceControllerInputMixin` takes the same bridging shape, under
/// differently-named getters only because its own backing field is itself
/// named differently.
mixin VoiceSessionAudioDevices {
  lk.Room? get _room;
  set _lastError(Object? value);
  CaptureNoiseSuppression get _capture;
  MicPort get _mic;
  bool get supportsInputGate;
  Future<void> _applyInputGate();

  AudioDeviceSwitching _audioSwitching = AudioDeviceSwitching(
    HardwareAudioDevices(),
  );

  /// Whether picking a specific microphone actually changes the live call;
  /// see [AudioDeviceSwitching.supportsInputSelection].
  bool get supportsAudioInputSelection =>
      _audioSwitching.supportsInputSelection;

  /// Whether picking a specific speaker actually changes playback; see
  /// [AudioDeviceSwitching.supportsOutputSelection].
  bool get supportsAudioOutputSelection =>
      _audioSwitching.supportsOutputSelection;

  /// The id of the microphone capture is on, null for the system default.
  String? get audioInputInUse => _audioSwitching.inputInUse;

  /// Fires when the platform's own device list changes, so a picker can
  /// refresh without polling.
  Stream<void> get audioDeviceChanges => _audioSwitching.onChange;

  /// A new stream starts on the sound server's default; this moves it onto
  /// the pick, now and again once playback has had a moment to open.
  void _followPreferredDevices() {
    // A reopened capture has no gate or suppressor on it until they are sent again.
    unawaited(_applyInputGate());
    Future<void> apply() =>
        _audioSwitching.applyServerRouting().catchError(ignoreError(
            LogTag.voice,
            'Could not move the call audio to the chosen device'));
    unawaited(apply());
    unawaited(Future<void>.delayed(const Duration(seconds: 3), apply));
  }

  /// The microphones this platform offers, for the picker.
  Future<List<AudioDevice>> audioInputDevices() =>
      _listAudioDevices(_audioSwitching.inputs);

  /// The speakers this platform offers, for the picker.
  Future<List<AudioDevice>> audioOutputDevices() =>
      _listAudioDevices(_audioSwitching.outputs);

  /// A device list that cannot be read must not stop a join.
  Future<void> _forgetUnpluggedDevices() async {
    try {
      await _audioSwitching.forgetUnpluggedPreferences();
    } catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'Could not forget unplugged audio devices; keeping the saved ones',
          error,
          stack);
    }
  }

  Future<List<AudioDevice>> _listAudioDevices(
    Future<List<AudioDevice>> Function() list,
  ) async {
    try {
      return await list();
    } catch (e, stack) {
      reportFailure(LogTag.voice, 'list audio devices', e, stack);
      _lastError = e;
      return const [];
    }
  }

  /// Switches the published microphone to [device] (null for the system
  /// default), live where this platform honours it, and remembered for the
  /// next join either way; see [AudioDeviceSwitching.selectInput].
  Future<bool> selectAudioInputDevice(AudioDevice? device) =>
      _trySelectAudio(() async {
        _capture.deviceChanged();
        // The reopen a switch does reuses the track's own options, not the room's.
        if (supportsInputGate) {
          _mic.adoptOptions(
            _audioSwitching.captureOptions(
              noiseSuppression: _capture.webrtcNoiseSuppression,
            ),
          );
        }
        final reopened = await _audioSwitching.selectInput(_room, device);
        if (reopened && supportsInputGate && _mic.open) {
          _capture.opened(
            webrtcNoiseSuppression: _capture.webrtcNoiseSuppression,
          );
        }
        _capture.retry();
      });

  /// [selectAudioInputDevice]'s counterpart for local playback.
  Future<bool> selectAudioOutputDevice(AudioDevice? device) =>
      _trySelectAudio(() => _audioSwitching.selectOutput(_room, device));

  Future<bool> _trySelectAudio(Future<void> Function() run) async {
    try {
      await run();
      return true;
    } catch (e, stack) {
      reportFailure(LogTag.voice, 'choose the audio device', e, stack);
      _lastError = e;
      return false;
    }
  }
}
