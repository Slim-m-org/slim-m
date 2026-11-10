// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pure half of the room walk that turns a call's remote video into the
/// tile keys [VideoSubscriptionCuller] reasons over.
///
/// [RemoteVideoPublicationRef] and [mapVideoSubscriptionRefs] are drivable
/// with no `lk.Room`, `lk.RemoteParticipant` or `lk.RemoteTrackPublication`
/// anywhere in sight - constructing any of those for real needs a
/// signalling server, a mock peer connection and a captured websocket (see
/// livekit_client's own `remote_track_publication_test.dart`, which stands
/// all three up just to build one publication). [lk.TrackSource] alone
/// crosses this seam, and it costs nothing to test with: a plain enum, the
/// same shape `ScreenShareControl`'s own tests already use
/// `lk.ScreenShareCaptureOptions` with no room anywhere near it.
///
/// The other half, walking a real `lk.Room` into these records, stays in
/// `VoiceVideoReceive` and stays untested for exactly that reason:
/// what it decides - which `lk.TrackSource` becomes which tile kind, that a
/// screen share is never confused with a camera, that audio never reaches a
/// culler at all - is entirely this function's decision, not the walk's.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'video_subscription_culler.dart';

/// One remote video publication, described without a live LiveKit object.
typedef RemoteVideoPublicationRef = ({
  String identity,
  lk.TrackSource source,
  bool subscribed,
  Future<void> Function() subscribe,
  Future<void> Function() unsubscribe,
});

/// Maps [publications] to the tile keys [VideoSubscriptionCuller] reasons
/// over.
///
/// A publication whose source the room walk did not classify as a camera or
/// a screen share (`lk.TrackSource.unknown`, which one carries before its
/// metadata lands, or any future source LiveKit adds) is skipped rather than
/// guessed at: a track nothing on the canvas has a tile for is a track no
/// interest set could ever name, so culling it would be culling on absence
/// of evidence.
Iterable<VideoSubscriptionRef> mapVideoSubscriptionRefs(
  Iterable<RemoteVideoPublicationRef> publications,
) sync* {
  for (final pub in publications) {
    final screenShare = switch (pub.source) {
      lk.TrackSource.camera => false,
      lk.TrackSource.screenShareVideo => true,
      _ => null,
    };
    if (screenShare == null) continue;
    yield (
      key: videoSubscriptionKey(
        identity: pub.identity,
        screenShare: screenShare,
      ),
      subscribed: pub.subscribed,
      subscribe: pub.subscribe,
      unsubscribe: pub.unsubscribe,
    );
  }
}
