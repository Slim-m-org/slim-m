// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [passesActivationThreshold], the pure function behind
/// [VoiceSession.setSpeakingSensitivity]. Driven directly with plain values
/// rather than a fake `lk.Participant` - the class is abstract and its own
/// constructors are private to `livekit_client`, so a real one cannot be
/// built here, the same limitation `camera_switching_test.dart`'s own doc
/// comment already names for a different livekit type.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('the SFU saying no is final, however loud the reported level', () {
    expect(passesActivationThreshold(false, 1.0, 1.0), isFalse);
  });

  test(
      'default sensitivity (1.0) matches behaviour before this existed: '
      'any reported level at all passes', () {
    expect(passesActivationThreshold(true, 0.0, 1.0), isTrue);
  });

  test('sensitivity 0 requires the loudest possible reported level', () {
    expect(passesActivationThreshold(true, 0.99, 0.0), isFalse);
    expect(passesActivationThreshold(true, 1.0, 0.0), isTrue);
  });

  test('the floor is linear between the two extremes', () {
    // sensitivity 0.5 -> floor 0.5.
    expect(passesActivationThreshold(true, 0.4, 0.5), isFalse);
    expect(passesActivationThreshold(true, 0.6, 0.5), isTrue);
  });

  test('a sensitivity outside 0-1 is clamped rather than inverted', () {
    expect(passesActivationThreshold(true, 0.01, 5.0), isTrue);
    expect(passesActivationThreshold(true, 0.99, -5.0), isFalse);
  });

  group('anyLiveVideo - a muted publication is not a live track', () {
    test('an unmuted camera publication reads as live', () {
      expect(
        anyLiveVideo(
          [(source: lk.TrackSource.camera, muted: false)],
          lk.TrackSource.camera,
        ),
        isTrue,
      );
    });

    test('a MUTED camera publication does not - the camera-off tile bug', () {
      expect(
        anyLiveVideo(
          [(source: lk.TrackSource.camera, muted: true)],
          lk.TrackSource.camera,
        ),
        isFalse,
        reason: 'turning a camera off mutes the publication rather than '
            'unpublishing it, so presence alone kept the tile showing a '
            'frozen frame instead of reverting to the avatar',
      );
    });

    test('a live screen share is not mistaken for a camera', () {
      expect(
        anyLiveVideo(
          [(source: lk.TrackSource.screenShareVideo, muted: false)],
          lk.TrackSource.camera,
        ),
        isFalse,
      );
    });

    test(
        'a muted camera alongside a live screen share still reads screen '
        'share live and camera off', () {
      final pubs = [
        (source: lk.TrackSource.camera, muted: true),
        (source: lk.TrackSource.screenShareVideo, muted: false),
      ];
      expect(anyLiveVideo(pubs, lk.TrackSource.camera), isFalse);
      expect(anyLiveVideo(pubs, lk.TrackSource.screenShareVideo), isTrue);
    });

    test('no publications at all is not live', () {
      expect(anyLiveVideo(const [], lk.TrackSource.camera), isFalse);
    });
  });

  group('deafened attribute', () {
    test('only the exact attribute value counts', () {
      expect(deafenedFromAttributes({kDeafenedAttribute: 'true'}), isTrue);
      expect(deafenedFromAttributes({kDeafenedAttribute: ''}), isFalse);
      expect(deafenedFromAttributes({kDeafenedAttribute: 'yes'}), isFalse);
      expect(deafenedFromAttributes(const {}), isFalse);
      expect(deafenedFromAttributes({'name': 'true'}), isFalse);
    });

    test('a participant that became deafened is not equal to before', () {
      const before = VoiceParticipant(
        identity: 'a',
        name: 'A',
        isSpeaking: false,
        isMuted: false,
        isLocal: false,
        isScreenSharing: false,
      );
      const after = VoiceParticipant(
        identity: 'a',
        name: 'A',
        isSpeaking: false,
        isMuted: false,
        isLocal: false,
        isScreenSharing: false,
        isDeafened: true,
      );
      expect(before == after, isFalse);
      expect(before.hashCode == after.hashCode, isFalse);
    });
  });
}
