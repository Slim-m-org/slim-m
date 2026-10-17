// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_controller.dart';

/// Per-participant playback volume, `voice_controller_audio_devices.dart`'s
/// own mixin-in-a-part shape for [VoiceController]'s 500-line hard ceiling.
mixin VoiceControllerParticipantVolumeMixin on StateNotifier<VoiceState> {
  VoiceSession get _inputSession;
  Ref get _inputRef;
  void _log(String message, {Object? detail});

  final Map<(String, LocalAudioChannel), TrailingThrottle<double>> _drags = {};
  final Set<(String, LocalAudioChannel)> _failing = {};

  /// Whether this host can change one participant's volume at all; see
  /// `audio_gain.dart` in the rtc package.
  bool get supportsParticipantVolume => _inputSession.supportsParticipantVolume;

  /// [identity]'s playback gain for this listener, 1.0 being unchanged.
  double volumeFor(String identity) => _inputSession.volumeFor(identity);

  /// [identity]'s screen share audio gain, apart from their voice.
  double screenVolumeFor(String identity) =>
      _inputSession.screenVolumeFor(identity);

  bool isScreenAudioMuted(String identity) =>
      _inputSession.isScreenAudioMuted(identity);

  Future<void> setScreenAudioMuted(String identity, bool muted) =>
      _inputSession.setScreenAudioMuted(identity, muted);

  /// Whether [identity] is publishing screen share audio right now.
  bool hasScreenAudio(String identity) =>
      _inputSession.hasScreenAudio(identity);

  /// Why the last volume change to [identity] did not land, or null.
  Object? volumeFailureFor(
    String identity, {
    LocalAudioChannel channel = LocalAudioChannel.voice,
  }) => _inputSession.volumeFailureFor(
    identity,
    screen: channel == LocalAudioChannel.screen,
  );

  /// Sets and saves [identity]'s voice volume for this listener only.
  ///
  /// Deliberately does not rebuild the controller state: this is dragged, and
  /// republishing the roster on every frame is what makes the call screen
  /// jank. The slider owns its own value while it moves.
  Future<void> setVolumeFor(String identity, double volume) =>
      _commitVolume(identity, volume, LocalAudioChannel.voice);

  /// Sets and saves [identity]'s screen share audio volume.
  Future<void> setScreenVolumeFor(String identity, double volume) =>
      _commitVolume(identity, volume, LocalAudioChannel.screen);

  /// A mid-drag value: applied on a short throttle and never saved. The
  /// release goes through [setVolumeFor] or [setScreenVolumeFor].
  Future<void> dragVolumeFor(
    String identity,
    double volume, {
    LocalAudioChannel channel = LocalAudioChannel.voice,
  }) => _dragThrottle(identity, channel).push(clampParticipantVolume(volume));

  TrailingThrottle<double> _dragThrottle(
    String identity,
    LocalAudioChannel channel,
  ) => _drags.putIfAbsent((
    identity,
    channel,
  ), () => TrailingThrottle((v) => _applyVolume(identity, v, channel)));

  Future<void> _commitVolume(
    String identity,
    double volume,
    LocalAudioChannel channel,
  ) async {
    final clamped = clampParticipantVolume(volume);
    _dragThrottle(identity, channel).cancel();
    unawaited(
      saveParticipantVolume(_inputRef, identity, clamped, channel: channel),
    );
    await _applyVolume(identity, clamped, channel);
  }

  Future<void> _applyVolume(
    String identity,
    double volume,
    LocalAudioChannel channel,
  ) async {
    final screen = channel == LocalAudioChannel.screen;
    await (screen
        ? _inputSession.setScreenVolumeFor(identity, volume)
        : _inputSession.setVolumeFor(identity, volume));
    final failure = _inputSession.volumeFailureFor(identity, screen: screen);
    if (failure == null) {
      _failing.remove((identity, channel));
    } else if (_failing.add((identity, channel))) {
      _log(
        'Volume change failed',
        detail: '${channel.name} audio for $identity: $failure',
      );
    }
  }

  /// Seeds the saved volumes into the session before any call exists, so
  /// someone turned down stays turned down after a restart.
  Future<void> restoreParticipantVolumes() async {
    final voice = await loadParticipantVolumes(_inputRef);
    for (final entry in voice.entries) {
      await _inputSession.setVolumeFor(entry.key, entry.value);
    }
    final screen = await loadParticipantVolumes(
      _inputRef,
      channel: LocalAudioChannel.screen,
    );
    for (final entry in screen.entries) {
      await _inputSession.setScreenVolumeFor(entry.key, entry.value);
    }
  }

  @override
  void dispose() {
    for (final throttle in _drags.values) {
      throttle.cancel();
    }
    super.dispose();
  }
}
