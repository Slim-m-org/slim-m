// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The space-wide screen-share resolution ceiling
/// (`Store::screen_share_max_height` on the server): `captureOptionsFor`'s
/// `maxHeight` clamp. Split from `screen_share_control_test.dart`, which is
/// at its file-size ceiling; the two share a class but not a file.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  group('the space-wide screen-share ceiling', () {
    test('leaves a tier already inside it untouched', () {
      final options = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality(ScreenShareResolution.p720, ScreenShareFps.fps60),
        null,
        isIOS: false,
        maxHeight: 2160,
      );

      expect(
        options.params.dimensions.height,
        ScreenShareQuality(ScreenShareResolution.p720, ScreenShareFps.fps60)
            .height,
      );
      expect(
        options.params.dimensions.width,
        ScreenShareQuality(ScreenShareResolution.p720, ScreenShareFps.fps60)
            .width,
      );
    });

    test('clamps a taller tier down to it, scaling width to match', () {
      // crisp is 2560x1440; a 720 ceiling must halve both, not just height.
      final options = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15),
        null,
        isIOS: false,
        maxHeight: 720,
      );

      expect(options.params.dimensions.height, 720);
      expect(options.params.dimensions.width, 1280);
    });

    test('leaves frame rate and bitrate alone: it bounds size only', () {
      final options = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15),
        null,
        isIOS: false,
        maxHeight: 720,
      );

      expect(
        options.params.encoding!.maxFramerate,
        ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15)
            .fps,
      );
      expect(
        options.params.encoding!.maxBitrate,
        ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15)
            .maxBitrate,
      );
    });

    test('also bounds an iOS capture, not only a desktop one', () {
      // The fixed 720x1280 phone capture must itself respect a lower ceiling.
      final options = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality.standard,
        null,
        isIOS: true,
        maxHeight: 640,
      );

      expect(options.params.dimensions.height, 640);
      expect(options.params.dimensions.width, 360);
    });

    test('null leaves every tier exactly as it always published', () {
      for (final quality in ScreenShareQuality.all) {
        final capped = ScreenShareControl.captureOptionsFor(
          quality,
          null,
          isIOS: false,
        );
        final uncapped = ScreenShareControl.captureOptionsFor(
          quality,
          null,
          isIOS: false,
          maxHeight: null,
        );

        expect(
          capped.params.dimensions.height,
          uncapped.params.dimensions.height,
        );
        expect(
          capped.params.dimensions.width,
          uncapped.params.dimensions.width,
        );
      }
    });
  });
}
