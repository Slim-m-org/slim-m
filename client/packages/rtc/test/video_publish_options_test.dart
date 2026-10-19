// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What reaches the encoder: the publish options per source and per quality.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

void main() {
  group('screen share publish options', () {
    test('carry the chosen tier\'s bitrate and fps for every quality', () {
      for (final q in ScreenShareQuality.all) {
        final options = screenSharePublishOptionsFor(q);
        expect(options.screenShareEncoding?.maxBitrate, q.maxBitrate,
            reason: q.id);
        expect(options.screenShareEncoding?.maxFramerate, q.fps, reason: q.id);
        expect(options.simulcast, isTrue, reason: q.id);
      }
    });

    test('keep text readable under pressure', () {
      final options = screenSharePublishOptionsFor(ScreenShareQuality.standard);
      expect(options.degradationPreference, lk.DegradationPreference.balanced);
    });

    test('differ between a 60 fps and a 15 fps tier', () {
      final fast = screenSharePublishOptionsFor(
        const ScreenShareQuality(
            ScreenShareResolution.p1080, ScreenShareFps.fps60),
      );
      final slow = screenSharePublishOptionsFor(
        const ScreenShareQuality(
            ScreenShareResolution.p1080, ScreenShareFps.fps15),
      );
      expect(fast.screenShareEncoding!.maxFramerate, 60);
      expect(slow.screenShareEncoding!.maxFramerate, 15);
    });

    test('the encoder reads the encoding, not the capture params', () {
      // computeVideoEncodings only consults publish options, so these must agree.
      const q = ScreenShareQuality.standard;
      final capture =
          ScreenShareControl.captureOptionsFor(q, null, isIOS: false);
      final publish = screenSharePublishOptionsFor(q);
      expect(publish.screenShareEncoding?.maxBitrate,
          capture.params.encoding?.maxBitrate);
      expect(publish.screenShareEncoding?.maxFramerate,
          capture.params.encoding?.maxFramerate);
    });

    test('leave the iOS broadcast extension capture size alone', () {
      final capture = ScreenShareControl.captureOptionsFor(
        const ScreenShareQuality(
            ScreenShareResolution.p2160, ScreenShareFps.fps60),
        null,
        isIOS: true,
      );
      expect(capture.params.dimensions.width, 720);
      expect(capture.params.dimensions.height, 1280);
    });
  });

  group('camera publish options', () {
    test('drop sharpness before smoothness', () {
      expect(cameraPublishOptions().degradationPreference,
          lk.DegradationPreference.maintainFramerate);
    });

    test('differ from the screen share preference', () {
      expect(
          cameraDegradationPreference, isNot(screenShareDegradationPreference));
    });
  });
}
