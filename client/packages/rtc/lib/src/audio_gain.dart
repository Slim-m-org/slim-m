// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Per-participant playback gain, and the honest answer about where it works.
///
/// livekit_client 2.10.0 has no per-participant volume API at all - only
/// whether a track plays. flutter_webrtc, already a direct dependency here,
/// does: `Helper.setVolume` sets receive-side gain on a track, on every
/// platform slim-m ships except the web, which this file exists to say.
///
/// **Android, iOS, macOS, Linux and Windows work.** A remote LiveKit track
/// arrives with a stream, so the native lookup finds it and real playback gain
/// is applied. Linux and Windows were once hidden here on the belief that the
/// shared `common/cpp` lookup could not find a Unified Plan track; measured on
/// Linux against a real LiveKit room on 2026-10-13, `setVolume` succeeds, and
/// the fork now also records tracks from `OnTrack` so the lookup cannot miss.
///
/// **Web silently does nothing.** There the call becomes
/// `applyConstraints({'volume': ...})`, and `volume` is not a constraint any
/// shipping browser honours (it was dropped from the spec after early
/// drafts), so the promise resolves having discarded it. Independently,
/// `applyConstraints` constrains a track's *source*, and a remote track's
/// source is the RTP receiver, which is not constrainable. LiveKit plays
/// remote audio on web through an `HTMLAudioElement` it owns and does not
/// expose, so there is no reachable handle to set volume on either.
///
/// Hence [supportsParticipantVolume]: the UI renders the control only where
/// it does something, which is the design's own "absent, never disabled"
/// rule; today that leaves out only the web.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

/// Loudest a participant may be made, as a multiplier. 200% matches the
/// design; past 1.0 this is digital gain on already-decoded audio, so it
/// clips rather than amplifying cleanly, which is why it stops here.
const double kMaxParticipantVolume = 2.0;

/// The default, and what every participant is until somebody moves a slider.
const double kDefaultParticipantVolume = 1.0;

/// Whether this platform can actually change one participant's playback gain.
///
/// False does not mean "not implemented here". It means the call would either
/// throw or quietly do nothing on this host; see the library doc for which,
/// per platform.
bool get supportsParticipantVolume => !lk.lkPlatformIs(lk.PlatformType.web);

/// Clamps a requested volume into the range the UI offers.
double clampParticipantVolume(double volume) =>
    volume.clamp(0.0, kMaxParticipantVolume);

/// Applies [volume] to one already-subscribed remote audio track.
///
/// A no-op where [supportsParticipantVolume] is false, so a caller does not
/// have to branch. Errors are returned rather than thrown: this runs inside
/// the per-track loop that reapplies local audio state on every room event,
/// which is fired and not awaited, so a throw would surface as an unhandled
/// zone error rather than as anything anybody could act on.
Future<Object?> applyParticipantVolume(lk.Track track, double volume) async {
  if (!supportsParticipantVolume) return null;
  try {
    await rtc.Helper.setVolume(
        clampParticipantVolume(volume), track.mediaStreamTrack);
    return null;
  } catch (e) {
    return e;
  }
}
