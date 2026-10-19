// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// The private half of viewport-driven video culling: turning the live room
/// into the plain records `mapVideoSubscriptionRefs` reasons over, and
/// handing the result to [VideoSubscriptionCuller].
///
/// Split out for [VoiceSession]'s own 500-line hard ceiling, the same reason
/// `voice_session_tracks.dart` exists, and everything here is private for
/// the same reason too - the one public method this feature adds
/// ([VoiceSession.setVideoInterest]) stays declared on the class itself, so
/// every `implements VoiceSession` fake in the test tree is a compile error
/// until it grows the method rather than silently missing it.
///
/// The room walk itself ([_remoteVideoPublications]) is the one part of this
/// still only read, not driven: see `remote_video_publication.dart`'s own
/// doc comment for why, and for what actually is tested - every decision
/// this walk hands off, rather than the walk itself.
extension VoiceSessionVideo on VoiceSession {
  /// Every remote video publication in the room, as the plain records
  /// `mapVideoSubscriptionRefs` turns into the tile keys the canvas's own
  /// `presenceTileKeys` keys a tile with.
  ///
  /// Walks `videoTrackPublications` only, so an audio publication is never
  /// reachable from here by construction - the first of the two independent
  /// guarantees that a cull can never silence anybody; the second is
  /// [VideoSubscriptionCuller]'s own refusal to act on a key whose kind is
  /// not in `cullableTrackKinds`.
  Iterable<RemoteVideoPublicationRef> _remoteVideoPublications(
    lk.Room room,
  ) sync* {
    for (final participant in room.remoteParticipants.values.toList()) {
      for (final pub in participant.videoTrackPublications.toList()) {
        yield (
          identity: participant.identity,
          source: pub.source,
          subscribed: pub.subscribed,
          subscribe: pub.subscribe,
          unsubscribe: pub.unsubscribe,
        );
      }
    }
  }

  /// Reconciles the room's remote video against whatever the last
  /// [VoiceSession.setVideoInterest] declared. Cheap enough to run on every
  /// room event, which is what it does: a publication's subscription state
  /// changes without the roster changing, so this cannot ride behind
  /// [VoiceSession._refreshParticipants]' own unchanged-roster early return.
  void _applyVideoInterest() {
    final room = _room;
    if (room == null || _disposed) return;
    _videoCuller.apply(
      mapVideoSubscriptionRefs(_remoteVideoPublications(room)),
    );
    _applyShareAudioBlock(room);
    _syncStallWatch();
  }

  /// A share's audio is its own publication, which the culler never sees, so a blocked share's is unsubscribed here and only here.
  void _applyShareAudioBlock(lk.Room room) {
    for (final participant in room.remoteParticipants.values) {
      final blocked = _videoCuller.blocked.contains(
        videoSubscriptionKey(
          identity: participant.identity,
          screenShare: true,
        ),
      );
      for (final pub in participant.audioTrackPublications) {
        if (pub.source != lk.TrackSource.screenShareAudio) continue;
        if (blocked == !pub.subscribed) continue;
        unawaited(
          (blocked ? pub.unsubscribe() : pub.subscribe()).catchError(
            (Object e) => _diag(
              'Could not change screen share audio: $e',
              level: LogLevel.warning,
            ),
          ),
        );
      }
    }
  }
}
