// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning a running share's audio off and on without ending the share.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

/// The local share audio publication, if the running share carries one.
lk.LocalTrackPublication<lk.LocalAudioTrack>? shareAudioPublication(
  lk.LocalParticipant? participant,
) =>
    participant?.audioTrackPublications
        .where((p) => p.source == lk.TrackSource.screenShareAudio)
        .firstOrNull;

/// Silences or restores the share audio in place.
/// `stopOnMute: false` keeps the capture open, because restarting it would ask the portal again on Linux.
Future<bool> setShareAudioMuted(
  lk.LocalParticipant? participant,
  bool muted,
) async {
  final pub = shareAudioPublication(participant);
  if (pub == null) return false;
  if (pub.muted == muted) return true;
  await (muted ? pub.mute(stopOnMute: false) : pub.unmute(stopOnMute: false));
  return pub.muted == muted;
}
