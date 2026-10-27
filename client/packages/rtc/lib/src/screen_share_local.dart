// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What [ShareRecovery] needs from the room: the running share's sender stats and its mute switch.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'call_stats.dart';
import 'screen_share.dart';
import 'screen_share_liveness.dart';

/// What a share was started with, so a restart repeats it.
class ShareRequest {
  const ShareRequest(
    this.quality,
    this.sourceId,
    this.includeAudio,
    this.maxHeight,
  );

  final ScreenShareQuality quality;
  final String? sourceId;
  final bool includeAudio;
  final int? maxHeight;
}

lk.LocalTrackPublication<lk.LocalVideoTrack>? _sharePublication(
  lk.LocalParticipant? participant,
) {
  final pub = participant?.getTrackPublicationBySource(
    lk.TrackSource.screenShareVideo,
  );
  return pub is lk.LocalTrackPublication<lk.LocalVideoTrack> ? pub : null;
}

/// Folds the sender's outbound-rtp entries, one per simulcast layer, into one reading.
ShareReading shareReadingOf(List<StatsEntry> entries) {
  int? frames;
  int? width;
  int? height;
  for (final e in entries) {
    if (e.type != 'outbound-rtp' || e.text('kind') == 'audio') continue;
    final sent = e.number('framesSent')?.toInt();
    if (sent != null) frames = (frames ?? 0) + sent;
    final w = e.number('frameWidth')?.toInt();
    final h = e.number('frameHeight')?.toInt();
    if (w != null &&
        h != null &&
        (width == null || w * h > width * (height ?? 0))) {
      width = w;
      height = h;
    }
  }
  return ShareReading(framesSent: frames, width: width, height: height);
}

/// The running share's stats, or null when there is no share with a sender to read.
Future<ShareReading?> readLocalShare(lk.LocalParticipant? participant) async {
  final sender = _sharePublication(participant)?.track?.sender;
  if (sender == null) return null;
  final reports = await sender.getStats();
  return shareReadingOf([for (final r in reports) StatsEntry.fromReport(r)]);
}

/// Mutes the share so receivers see their paused placeholder; the capture stays open to recover on its own.
Future<void> pauseLocalShare(
  lk.LocalParticipant? participant,
  bool paused,
) async {
  final pub = _sharePublication(participant);
  if (pub == null || pub.muted == paused) return;
  await (paused ? pub.mute(stopOnMute: false) : pub.unmute(stopOnMute: false));
}
