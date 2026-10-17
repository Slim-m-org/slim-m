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
/// **Web runs its own gain.** There `Helper.setVolume` becomes
/// `applyConstraints({'volume': ...})`, which no shipping browser honours, and
/// LiveKit hides the `HTMLAudioElement` it plays through. So `web_gain.dart`
/// finds that element by its documented id, routes its stream through a Web
/// Audio `GainNode` (which, unlike `element.volume`, can exceed 1.0) and mutes
/// the element so nothing plays twice.
///
/// Hence [supportsParticipantVolume], true everywhere the client ships.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'web_gain_io.dart' if (dart.library.js_interop) 'web_gain_web.dart'
    as web_gain;

/// Loudest a participant may be made, as a multiplier. 200% matches the
/// design; past 1.0 this is digital gain on already-decoded audio, so it
/// clips rather than amplifying cleanly, which is why it stops here.
const double kMaxParticipantVolume = 2.0;

/// The default, and what every participant is until somebody moves a slider.
const double kDefaultParticipantVolume = 1.0;

/// Whether this platform can change one participant's playback gain.
bool get supportsParticipantVolume => true;

/// Clamps a requested volume into the range the UI offers.
double clampParticipantVolume(double volume) =>
    volume.clamp(0.0, kMaxParticipantVolume);

/// Applies [volume] to one already-subscribed remote audio track.
///
/// Errors are returned rather than thrown: this runs inside the per-track
/// loop that reapplies local audio state on every room event, which is fired
/// and not awaited, so a throw would surface as an unhandled zone error
/// rather than as anything anybody could act on.
Future<Object?> applyParticipantVolume(lk.Track track, double volume) async {
  final clamped = clampParticipantVolume(volume);
  try {
    if (lk.lkPlatformIs(lk.PlatformType.web)) {
      return web_gain.applyWebGain(track.getCid(), clamped);
    }
    await rtc.Helper.setVolume(clamped, track.mediaStreamTrack);
    return null;
  } catch (e) {
    return e;
  }
}
