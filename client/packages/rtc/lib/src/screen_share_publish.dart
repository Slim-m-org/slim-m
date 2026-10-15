// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Publishing a screen share with explicit publish options.
///
/// `LocalParticipant.setScreenShareEnabled` always publishes with the room's
/// defaults, which are fixed at connect time, so a per-share quality needs the
/// track created and published here instead.
library;

import 'package:livekit_client/livekit_client.dart' as lk;
// ignore: implementation_imports
import 'package:livekit_client/src/managers/broadcast_manager.dart'
    as lk_broadcast;

/// Starts or stops the share on [participant]. [publishOptions] is only used
/// when a new track is published.
Future<void> publishScreenShare(
  lk.LocalParticipant? participant, {
  required bool enabled,
  required lk.ScreenShareCaptureOptions? options,
  required bool includeAudio,
  required lk.VideoPublishOptions publishOptions,
}) async {
  if (participant == null) return;
  if (!_publishesDirectly(participant, enabled)) {
    await participant.setScreenShareEnabled(
      enabled,
      captureScreenAudio: includeAudio,
      screenShareCaptureOptions: options,
    );
    return;
  }
  final captureOptions = options ?? const lk.ScreenShareCaptureOptions();
  final tracks = includeAudio
      ? await lk.LocalVideoTrack.createScreenShareTracksWithAudio(
          captureOptions,
        )
      : [await lk.LocalVideoTrack.createScreenShareTrack(captureOptions)];
  try {
    for (final track in tracks) {
      if (track is lk.LocalVideoTrack) {
        await participant.publishVideoTrack(
          track,
          publishOptions: publishOptions,
        );
      } else if (track is lk.LocalAudioTrack) {
        await participant.publishAudioTrack(track);
      }
    }
  } catch (_) {
    for (final track in tracks) {
      await track.stop();
    }
    rethrow;
  }
}

// Stopping, unmuting an existing share, and iOS before its broadcast starts stay on LiveKit's own path.
bool _publishesDirectly(lk.LocalParticipant participant, bool enabled) {
  if (!enabled) return false;
  final existing = participant.getTrackPublicationBySource(
    lk.TrackSource.screenShareVideo,
  );
  if (existing != null) return false;
  final onIOS = lk.lkPlatformIs(lk.PlatformType.iOS);
  return !onIOS || lk_broadcast.BroadcastManager().isBroadcasting;
}
