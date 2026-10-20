// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('shared audio publishes at a music bitrate', () {
    final options = screenShareAudioPublishOptions();
    expect(options.encoding?.maxBitrate, greaterThanOrEqualTo(64000));
    expect(options.encoding, isNot(microphonePublishOptions().encoding));
  });

  test('shared audio does not use DTX', () {
    expect(screenShareAudioPublishOptions().dtx, isFalse);
  });

  test('shared audio skips redundant audio, which would double its bitrate',
      () {
    // 2.13.1 sends this field as disableRed, so true is the one that disables RED.
    expect(screenShareAudioPublishOptions().red, isTrue);
    expect(microphonePublishOptions().red, isFalse);
  });

  test('no voice processing is requested for shared audio', () {
    final options = screenShareAudioCaptureOptions();
    expect(options.echoCancellation, isFalse);
    expect(options.noiseSuppression, isFalse);
    expect(options.autoGainControl, isFalse);
    expect(options.highPassFilter, isFalse);
    expect(options.voiceIsolation, isFalse);
    expect(options.typingNoiseDetection, isFalse);
  });

  test('a microphone change skips the screen share audio track', () {
    final sources = [
      lk.TrackSource.microphone,
      lk.TrackSource.screenShareAudio,
      lk.TrackSource.microphone,
    ];
    final kept = voiceSourced(sources, (s) => s).toList();
    expect(kept, [lk.TrackSource.microphone, lk.TrackSource.microphone]);
  });
}
