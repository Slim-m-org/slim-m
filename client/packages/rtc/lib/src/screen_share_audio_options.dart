// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How shared audio (a game, a video, music) is captured and published.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Music-grade and unprocessed, unlike the speech-tuned [microphonePublishOptions].
///
/// `red: true` turns redundant audio OFF (the flag is inverted in
/// livekit_client 2.13.1): RED would double a 96 kbps stream for little gain.
lk.AudioPublishOptions screenShareAudioPublishOptions() =>
    const lk.AudioPublishOptions(
      encoding: lk.AudioEncoding.presetMusicHighQuality,
      dtx: false,
      red: true,
      name: 'screen_share_audio',
    );

/// What a browser's display audio track is told to stop doing; the same switches
/// [lk.AudioCaptureOptions] names, in the standard constraint spelling.
const Map<String, dynamic> unprocessedAudioConstraints = {
  'echoCancellation': false,
  'noiseSuppression': false,
  'autoGainControl': false,
};

/// Turns voice processing off on a captured share audio track, where it can be.
///
/// LiveKit's `getDisplayMedia` call only takes `audio: true`, so the options
/// cannot ride on the capture. A browser accepts them afterwards through
/// `applyConstraints`; the native plugin's `applyConstraints` handles volume
/// only, and the desktop fork's loopback source is never processed anyway.
Future<void> unprocessShareAudio(
  rtc.MediaStreamTrack track, {
  @visibleForTesting lk.PlatformType? platform,
}) async {
  if ((platform ?? lk.lkPlatform()) != lk.PlatformType.web) return;
  try {
    await track.applyConstraints(unprocessedAudioConstraints);
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.voice,
      'The browser kept voice processing on shared audio',
      error,
      stack,
    );
  }
}

/// Keeps what carries a voice, so a microphone-only change skips shared audio.
Iterable<T> voiceSourced<T>(
  Iterable<T> items,
  lk.TrackSource Function(T item) sourceOf,
) =>
    items.where((item) => sourceOf(item) == lk.TrackSource.microphone);

/// Publishes the captured share audio with its own options.
Future<void> publishScreenShareAudio(
  lk.LocalParticipant participant,
  lk.LocalAudioTrack track,
) async {
  await unprocessShareAudio(track.mediaStreamTrack);
  await participant.publishAudioTrack(
    track,
    publishOptions: screenShareAudioPublishOptions(),
  );
}
