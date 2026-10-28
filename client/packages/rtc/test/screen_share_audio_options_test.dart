// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _Track extends Fake implements rtc.MediaStreamTrack {
  _Track({this.refuse = false});

  final bool refuse;
  final applied = <Map<String, dynamic>?>[];

  @override
  Future<void> applyConstraints([Map<String, dynamic>? constraints]) async {
    applied.add(constraints);
    if (refuse) throw StateError('OverconstrainedError');
  }
}

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

  group('unprocessed capture', () {
    test('a browser is told to drop echo, noise and gain processing', () async {
      final track = _Track();

      await unprocessShareAudio(track, platform: lk.PlatformType.web);

      expect(track.applied, [
        unprocessedAudioConstraints,
        ownAudioExcludedConstraints,
      ]);
      expect(unprocessedAudioConstraints, {
        'echoCancellation': false,
        'noiseSuppression': false,
        'autoGainControl': false,
      });
    });

    test('a native track is left alone, its capture is already raw', () async {
      final track = _Track();

      await unprocessShareAudio(track, platform: lk.PlatformType.linux);

      expect(track.applied, isEmpty);
    });

    test('a browser that refuses the constraints does not fail the share',
        () async {
      final track = _Track(refuse: true);

      await unprocessShareAudio(track, platform: lk.PlatformType.web);

      expect(track.applied, hasLength(2), reason: 'each ask is tried alone');
    });
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
