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
}
