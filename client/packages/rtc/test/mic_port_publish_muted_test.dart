// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A push-to-talk join publishes a silent track, never a live one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _Stream implements rtc.MediaStream {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _PlatformTrack implements rtc.MediaStreamTrack {
  @override
  bool enabled = true;
  @override
  String? get id => 'fake';
  @override
  Function()? onEnded;
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

lk.LocalAudioTrack _track(_PlatformTrack platform) =>
    // ignore: invalid_use_of_internal_member
    lk.LocalAudioTrack(
      lk.TrackSource.microphone,
      _Stream(),
      platform,
      const lk.AudioCaptureOptions(),
    );

void main() {
  test('the platform track is silent when publishing starts the capture',
      () async {
    final platform = _PlatformTrack();
    final track = _track(platform);
    addTearDown(track.stop);
    bool? enabledWhenAdded;

    await publishAudioTrackMuted(track, (t) async {
      // The same order livekit's publishAudioTrack runs in: start, then the request.
      await t.start();
      enabledWhenAdded = t.mediaStreamTrack.enabled;
      return null;
    });

    expect(enabledWhenAdded, isFalse);
    expect(track.muted, isTrue);
  });

  test('a failed publish stops the capture and rethrows', () async {
    final platform = _PlatformTrack();
    final track = _track(platform);

    await expectLater(
      publishAudioTrackMuted(track, (_) async => throw StateError('no')),
      throwsStateError,
    );
    expect(track.isActive, isFalse);
  });
}
