// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice session's own listening state: deafen, per-participant mute and gain.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'audio_gain.dart' as rtc_gain;
import 'local_audio.dart';

/// What [VoiceListenerAudio] needs from the session that owns it.
class VoiceListenerAudioHost {
  const VoiceListenerAudioHost({
    required this.room,
    required this.noteError,
    required this.refresh,
  });

  final lk.Room? Function() room;
  final void Function(Object error) noteError;
  final void Function() refresh;
}

/// Deafen, per-participant mute and per-participant gain, which are one
/// listener's own business and never reach the room; see [LocalAudioState].
class VoiceListenerAudio {
  VoiceListenerAudio(this._host);

  final VoiceListenerAudioHost _host;
  final LocalAudioState audio = LocalAudioState();

  bool get deafened => audio.deafened;

  /// Whether [identity] is silenced for this listener alone.
  bool isLocallyMuted(String identity) => audio.isMuted(identity);

  /// Whether this host can change one participant's volume at all; see
  /// [rtc_gain.supportsParticipantVolume].
  bool get supportsParticipantVolume => rtc_gain.supportsParticipantVolume;

  /// [identity]'s playback gain for this listener, 1.0 being unchanged.
  double volumeFor(String identity) => audio.volumeFor(identity);

  /// Sets [identity]'s playback gain for this listener only, clamped to the
  /// range the UI offers.
  ///
  /// Stored as well as applied, and reapplied by [apply] on every room event,
  /// because native gain lives on the platform track object and a track that
  /// resubscribes arrives as a new one at full volume. A setter that only
  /// touched currently-subscribed tracks would pass every test and quietly
  /// reset somebody whose network blipped.
  Future<void> setVolumeFor(String identity, double volume) async {
    audio.setVolumeFor(identity, volume);
    await _applyIfInCall();
  }

  /// [identity]'s screen share audio gain, kept apart from their voice.
  double screenVolumeFor(String identity) =>
      audio.volumeFor(identity, channel: LocalAudioChannel.screen);

  /// Sets [identity]'s screen share audio gain for this listener only.
  Future<void> setScreenVolumeFor(String identity, double volume) async {
    audio.setVolumeFor(identity, volume, channel: LocalAudioChannel.screen);
    await _applyIfInCall();
  }

  /// Whether [identity]'s screen share audio alone is silenced for you.
  bool isScreenAudioMuted(String identity) => audio.isScreenMuted(identity);

  /// Silences (or restores) only [identity]'s screen share audio.
  Future<void> setScreenAudioMuted(String identity, bool muted) async {
    audio.setScreenMuted(identity, muted);
    await _applyIfInCall();
  }

  /// Whether [identity] is publishing screen share audio right now.
  bool hasScreenAudio(String identity) {
    final room = _host.room();
    return room != null && audio.hasScreenAudio(room, identity);
  }

  /// Why the last gain change to [identity] did not land, or null if it did.
  Object? volumeFailureFor(String identity, {bool screen = false}) =>
      audio.failureFor(
        identity,
        channel: screen ? LocalAudioChannel.screen : LocalAudioChannel.voice,
      );

  /// Silences (or restores) one participant, for this listener only.
  ///
  /// Reapplied on every room event through [apply], so a track that
  /// resubscribes after the mute stays silenced without this class tracking
  /// subscriptions itself.
  Future<void> setLocallyMuted(String identity, bool muted) async {
    audio.setMuted(identity, muted);
    await _applyIfInCall();
    _host.refresh();
  }

  /// Silences (or restores) every remote participant's audio locally: the
  /// media track at once, and the SFU's forwarding of it with one signalling
  /// message, with no renegotiation either way. Returns whether it took effect, matching
  /// the microphone and screen share toggles' own convention: no room, no effect.
  Future<bool> setDeafened(bool deafened) async {
    final room = _host.room();
    if (room == null) return false;
    audio.deafened = deafened;
    await apply(room);
    _host.refresh();
    return true;
  }

  /// Delegates to [LocalAudioState.applyTo]; see that class for why this
  /// runs on every room event rather than only when a control moves.
  Future<void> apply(lk.Room room) async {
    final failure = await audio.applyTo(room);
    if (failure != null) _host.noteError(failure);
  }

  /// Forgets what a call set on this listener, keeping every gain: somebody
  /// you turned down stays turned down.
  void resetForNewCall() {
    audio.deafened = false;
    audio.muted.clear();
    audio.screenMuted.clear();
  }

  Future<void> _applyIfInCall() async {
    final room = _host.room();
    if (room != null) await apply(room);
  }
}
