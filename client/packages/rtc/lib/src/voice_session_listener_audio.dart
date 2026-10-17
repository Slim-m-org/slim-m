// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s own listening state: deafen, per-participant mute and
/// gain. A mixin for the reason `voice_session_audio_devices.dart` gives.
mixin VoiceSessionListenerAudio {
  lk.Room? get _room;
  set _lastError(Object? value);
  void _refreshParticipants();

  /// Deafen, per-participant mute and per-participant gain, which are one
  /// listener's own business and never reach the room; see [LocalAudioState].
  final LocalAudioState _audio = LocalAudioState();

  bool get deafened => _audio.deafened;

  /// Whether [identity] is silenced for this listener alone.
  bool isLocallyMuted(String identity) => _audio.isMuted(identity);

  /// Whether this host can change one participant's volume at all. See
  /// [supportsParticipantVolume]: on the platforms that answer false the call
  /// would either throw or quietly do nothing, so the control is not offered.
  bool get supportsParticipantVolume => rtc_gain.supportsParticipantVolume;

  /// [identity]'s playback gain for this listener, 1.0 being unchanged.
  double volumeFor(String identity) => _audio.volumeFor(identity);

  /// Sets [identity]'s playback gain for this listener only, clamped to the
  /// range the UI offers.
  ///
  /// Stored as well as applied, and reapplied from [_applyLocalAudioState] on
  /// every room event, because native gain lives on the platform track object
  /// and a track that resubscribes arrives as a new one at full volume. A
  /// setter that only touched currently-subscribed tracks would pass every
  /// test and quietly reset somebody whose network blipped.
  Future<void> setVolumeFor(String identity, double volume) async {
    _audio.setVolumeFor(identity, volume);
    final room = _room;
    if (room != null) await _applyLocalAudioState(room);
  }

  /// Silences (or restores) one participant, for this listener only.
  ///
  /// Reapplied on every room event through [_applyLocalAudioState], so a track
  /// that resubscribes after the mute stays silenced without this class
  /// tracking subscriptions itself.
  Future<void> setLocallyMuted(String identity, bool muted) async {
    _audio.setMuted(identity, muted);
    final room = _room;
    if (room != null) await _applyLocalAudioState(room);
    _refreshParticipants();
  }

  /// Silences (or restores) every remote participant's audio locally, by
  /// disabling the underlying WebRTC track rather than unsubscribing from
  /// it: a track publication's own `disable()` drops the SFU subscription
  /// and would need renegotiation before sound comes back, while flipping
  /// the underlying media track's `enabled` flag is a local, instant, and
  /// instantly reversible mute. Returns whether it took effect, matching
  /// [setMicrophoneEnabled] and [setScreenShareEnabled]'s own convention: no
  /// room, no effect.
  Future<bool> setDeafened(bool deafened) async {
    final room = _room;
    if (room == null) return false;
    _audio.deafened = deafened;
    await _applyLocalAudioState(room);
    return true;
  }

  /// Delegates to [LocalAudioState.applyTo]; see that class for why this
  /// runs on every room event rather than only when a control moves.
  Future<void> _applyLocalAudioState(lk.Room room) async {
    final failure = await _audio.applyTo(room);
    if (failure != null) _lastError = failure;
  }
}
