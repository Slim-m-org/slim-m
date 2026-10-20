// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How shared audio (a game, a video, music) is captured and published.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

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

/// Nothing speech-shaped in the chain, whatever the voice settings say.
lk.AudioCaptureOptions screenShareAudioCaptureOptions() =>
    const lk.AudioCaptureOptions(
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false,
      highPassFilter: false,
      voiceIsolation: false,
      typingNoiseDetection: false,
    );

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
) {
  track.currentOptions = screenShareAudioCaptureOptions();
  return participant.publishAudioTrack(
    track,
    publishOptions: screenShareAudioPublishOptions(),
  );
}
