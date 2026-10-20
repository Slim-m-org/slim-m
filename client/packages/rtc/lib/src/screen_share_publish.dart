// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Publishing a screen share with explicit publish options.
///
/// `LocalParticipant.setScreenShareEnabled` always publishes with the room's
/// defaults, which are fixed at connect time, so a per-share quality needs the
/// track created and published here instead.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'screen_share.dart';
import 'screen_share_audio_options.dart';
import 'screen_share_source_size.dart';
import 'video_publish_options.dart';
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
  required ScreenShareQuality quality,
  int? maxHeight,
  Future<({int width, int height})?> Function(rtc.MediaStream stream)?
      measureSource,
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
        final fitted = await _fitToSource(
          track,
          quality,
          maxHeight,
          measureSource ?? measureCapturedSize,
        );
        await participant.publishVideoTrack(
          track,
          publishOptions: screenSharePublishOptionsFor(fitted),
        );
      } else if (track is lk.LocalAudioTrack) {
        await publishScreenShareAudio(participant, track);
      }
    }
  } catch (_) {
    for (final track in tracks) {
      await track.stop();
    }
    rethrow;
  }
}

/// Corrects [track]'s options so LiveKit lays out its layers for the size actually captured.
Future<ScreenShareQuality> _fitToSource(
  lk.LocalVideoTrack track,
  ScreenShareQuality quality,
  int? maxHeight,
  Future<({int width, int height})?> Function(rtc.MediaStream) measure,
) async {
  final size = await measure(track.mediaStream);
  if (size == null) return quality;
  final fit = fitScreenShare(
    quality,
    sourceWidth: size.width,
    sourceHeight: size.height,
    maxHeight: maxHeight,
  );
  final dimensions = track.currentOptions.params.dimensions;
  if (fit.quality == quality &&
      fit.width == dimensions.width &&
      fit.height == dimensions.height) {
    return quality;
  }
  track.currentOptions =
      (track.currentOptions as lk.ScreenShareCaptureOptions).copyWith(
    params: lk.VideoParameters(
      dimensions: lk.VideoDimensions(fit.width, fit.height),
      encoding: lk.VideoEncoding(
        maxBitrate: fit.quality.maxBitrate,
        maxFramerate: fit.quality.fps,
      ),
    ),
  );
  return fit.quality;
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
