// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_controller.dart';

/// Microphone and speaker device selection, `voice_controller_input.dart`'s
/// own mixin-in-a-part shape for [VoiceController]'s 500-line hard ceiling,
/// reaching the same `_inputSession`/`_inputRef` bridge that mixin already
/// declares.
mixin VoiceControllerAudioDevicesMixin on StateNotifier<VoiceState> {
  VoiceSession get _inputSession;
  Ref get _inputRef;

  /// Whether picking a specific microphone changes anything live; see
  /// [VoiceSession.supportsAudioInputSelection].
  bool get supportsAudioInputSelection =>
      _inputSession.supportsAudioInputSelection;

  /// Whether picking a specific speaker changes anything live; see
  /// [VoiceSession.supportsAudioOutputSelection].
  bool get supportsAudioOutputSelection =>
      _inputSession.supportsAudioOutputSelection;

  /// The speaker in use, null for the system default; see
  /// [VoiceSession.audioOutputInUse].
  String? get audioOutputInUse => _inputSession.audioOutputInUse;

  /// Fires when the platform's own device list changes; see
  /// [VoiceSession.audioDeviceChanges].
  Stream<void> get audioDeviceChanges => _inputSession.audioDeviceChanges;

  /// The microphones available to pick from.
  Future<List<AudioDevice>> audioInputDevices() =>
      _inputSession.audioInputDevices();

  /// The speakers available to pick from.
  Future<List<AudioDevice>> audioOutputDevices() =>
      _inputSession.audioOutputDevices();

  /// Seeds the persisted microphone/speaker choice before any call exists;
  /// [VoiceController.restoreCameraPreference]'s own shape for audio. Only
  /// the id survives a restart (see `voice_settings_controller.dart`), so a
  /// bare label stands in here - nothing reads it until a real [AudioDevice]
  /// from a fresh enumeration replaces it.
  Future<void> restoreAudioDevicePreferences() async {
    final (inputId, outputId) = await loadAudioDevicePreferences(_inputRef);
    await _inputSession.selectAudioInputDevice(_asPreference(inputId));
    await _inputSession.selectAudioOutputDevice(_asPreference(outputId));
  }

  AudioDevice? _asPreference(String? id) =>
      id == null ? null : AudioDevice(id: id, label: id);

  /// Seeds the fallback switch before any call; see [VoiceSession.setMicFallbackEnabled].
  Future<void> restoreMicFallback() async {
    _inputSession.setMicFallbackEnabled(
      await loadMicFallbackEnabled(_inputRef),
    );
  }

  void setMicFallbackEnabled(bool enabled) =>
      _inputSession.setMicFallbackEnabled(enabled);

  /// The microphone the call switched to on its own; null once dismissed.
  String? get micFallbackNotice => _inputSession.micFallbackNotice;
  Stream<String?> get micFallbackNotices => _inputSession.micFallbackNotices;
  void dismissMicFallbackNotice() => _inputSession.dismissMicFallbackNotice();

  /// Switches the microphone to [device] (null for the system default),
  /// live or at the next join; see [VoiceSession.selectAudioInputDevice].
  Future<bool> selectAudioInputDevice(AudioDevice? device) async {
    final ok = await _inputSession.selectAudioInputDevice(device);
    state = state.copyWith(
      error: ok ? null : 'Could not switch to that microphone.',
      clearError: ok,
    );
    return ok;
  }

  /// [selectAudioInputDevice]'s counterpart for output.
  Future<bool> selectAudioOutputDevice(AudioDevice? device) async {
    final ok = await _inputSession.selectAudioOutputDevice(device);
    state = state.copyWith(
      error: ok ? null : 'Could not switch to that speaker.',
      clearError: ok,
    );
    return ok;
  }

  /// Whether the microphone is healthy, coming back, or given up on; see
  /// [VoiceSession.micStatus].
  MicStatus get micStatus => _inputSession.micStatus;
  Stream<MicStatus> get micStatuses => _inputSession.micStatuses;

  /// Why the microphone last failed to open; see [VoiceSession.micFailure].
  MicFailureReason? get micFailure => _inputSession.micFailure;
  Stream<MicFailureReason?> get micFailures => _inputSession.micFailures;

  /// Tells the call this client deafened or undeafened itself.
  Future<void> publishDeafenedState(bool deafened) => publishDeafened(
    _inputRef.read(apiProvider),
    state.channelId,
    deafened: deafened,
    onError: (e) => api.AppLog.swallowed(
      api.LogTag.voice,
      'Could not tell the call this client is deafened',
      e,
      null,
    ),
  );

  /// The mic button's tap-to-retry once recovery gave up: reopens the capture
  /// even when the device is unchanged; see [VoiceSession.resetMicrophone].
  Future<bool> resetMicrophone() async {
    final ok = await _inputSession.resetMicrophone();
    if (!ok) state = state.copyWith(error: 'Could not reset the microphone.');
    return ok;
  }
}
