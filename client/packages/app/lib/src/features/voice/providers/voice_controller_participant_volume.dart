// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_controller.dart';

/// Per-participant playback volume, `voice_controller_audio_devices.dart`'s
/// own mixin-in-a-part shape for [VoiceController]'s 500-line hard ceiling.
mixin VoiceControllerParticipantVolumeMixin on StateNotifier<VoiceState> {
  VoiceSession get _inputSession;
  Ref get _inputRef;

  /// Whether this host can change one participant's volume at all; see
  /// `audio_gain.dart` in the rtc package for which platforms cannot.
  bool get supportsParticipantVolume => _inputSession.supportsParticipantVolume;

  /// [identity]'s playback gain for this listener, 1.0 being unchanged.
  double volumeFor(String identity) => _inputSession.volumeFor(identity);

  /// Sets and saves [identity]'s playback gain for this listener only.
  ///
  /// Deliberately does not rebuild the controller state: this is dragged, and
  /// republishing the roster on every frame is what makes the call screen
  /// jank. The slider owns its own value while it moves.
  Future<void> setVolumeFor(String identity, double volume) async {
    final clamped = clampParticipantVolume(volume);
    unawaited(saveParticipantVolume(_inputRef, identity, clamped));
    await _inputSession.setVolumeFor(identity, clamped);
  }

  /// Seeds the saved volumes into the session before any call exists, so
  /// someone turned down stays turned down after a restart.
  Future<void> restoreParticipantVolumes() async {
    final saved = await loadParticipantVolumes(_inputRef);
    for (final entry in saved.entries) {
      await _inputSession.setVolumeFor(entry.key, entry.value);
    }
  }
}
