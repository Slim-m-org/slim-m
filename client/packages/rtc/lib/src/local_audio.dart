// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What one listener has done about what reaches their own ears: deafen,
/// silence one person, or turn one person up or down. All of it is local and
/// never announced, so nobody learns they were muted.
///
/// It is reapplied on every room event so a rejoined or resubscribed track
/// keeps the listener's choice, skipping a push only when the track already
/// has that state. Why it reads the track back rather than trusting what it
/// asked for is in docs/research/mic-handling.md.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'audio_gain.dart';

/// One subscribed remote audio track as plain closures, so tests can see
/// which calls are made. [track] keys the volume cache and must be the
/// object the closures act on; [isAudible] reads its current state cheaply.
typedef LocalAudioRef = ({
  String identity,
  Object track,
  bool Function() isAudible,
  Future<void> Function() enable,
  Future<void> Function() disable,
  Future<Object?> Function(double volume) setVolume,
});

/// The gain last successfully pushed to one platform track.
///
/// Only gain. Whether a track is silenced is read back from the track itself
/// rather than remembered, so nothing here can disagree with the device.
class _AppliedAudio {
  const _AppliedAudio({required this.volume});

  final double volume;
}

class LocalAudioState {
  /// Silences every remote participant.
  bool deafened = false;

  /// Identities silenced individually.
  final Set<String> muted = {};

  /// Per-identity gain, absent meaning [kDefaultParticipantVolume].
  ///
  /// Deliberately not carried on the participant value type: that list is
  /// compared by value to decide whether to push a new roster to every
  /// listener, so a gain field would turn each pixel of a slider drag into a
  /// full roster rebuild.
  final Map<String, double> volumes = {};

  double volumeFor(String identity) =>
      volumes[identity] ?? kDefaultParticipantVolume;

  void setVolumeFor(String identity, double volume) {
    volumes[identity] = clampParticipantVolume(volume);
  }

  void setMuted(String identity, bool value) {
    value ? muted.add(identity) : muted.remove(identity);
  }

  bool isMuted(String identity) => muted.contains(identity);

  /// Applies all three to every remote audio track currently subscribed,
  /// returning the last failure or null.
  ///
  /// Failures are returned rather than thrown because the caller fires this
  /// without awaiting from a room-event handler, where a throw would become
  /// an unhandled zone error instead of something anybody could act on.
  ///
  /// Disabling the media track rather than unsubscribing is deliberate: a
  /// publication's own `disable()` drops the SFU subscription and needs
  /// renegotiation before sound comes back, while the track's `enabled` flag
  /// is local, instant, and instantly reversible.
  Future<Object?> applyTo(lk.Room room) => applyToRefs(refsOf(room));

  /// Every subscribed remote audio track in [room], as [LocalAudioRef]s.
  Iterable<LocalAudioRef> refsOf(lk.Room room) sync* {
    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (track == null) continue;
        yield (
          identity: participant.identity,
          track: track.mediaStreamTrack,
          isAudible: () => track.mediaStreamTrack.enabled,
          enable: track.enable,
          disable: track.disable,
          setVolume: (volume) => applyParticipantVolume(track, volume),
        );
      }
    }
  }

  /// The half of [applyTo] worth testing, over an explicit track list.
  Future<Object?> applyToRefs(Iterable<LocalAudioRef> refs) async {
    Object? failure;
    for (final ref in refs) {
      // Deafened silences everyone; otherwise only the individually muted.
      final silence = deafened || muted.contains(ref.identity);
      final audible = ref.isAudible();

      if (silence) {
        if (!audible) continue;
        try {
          await ref.disable();
        } catch (e) {
          failure = e;
        }
        // Whatever was believed about gain stops being true once it is silent.
        _applied[ref.track] = null;
        continue;
      }

      final volume = volumeFor(ref.identity);
      final last = _applied[ref.track];
      if (audible && last != null && last.volume == volume) continue;

      Object? here;
      try {
        await ref.enable();
      } catch (e) {
        here = e;
      }
      // After the enable, never before: re-enabling can reset source volume.
      here = await ref.setVolume(volume) ?? here;

      // Remembered only if it both went cleanly and can be seen to have landed.
      _applied[ref.track] = here == null && ref.isAudible()
          ? _AppliedAudio(volume: volume)
          : null;
      failure = here ?? failure;
    }
    return failure;
  }

  /// Weakly keyed, so remembering a track never keeps a finished call's
  /// platform objects alive.
  final Expando<_AppliedAudio> _applied = Expando('local audio last applied');
}
