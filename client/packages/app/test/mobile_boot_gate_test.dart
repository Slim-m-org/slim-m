// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When a phone's startup splash stays up past bootstrap: through the resting
/// `offline` and the first `connecting` attempt, and gone for good the moment
/// that first attempt fails - so an offline phone is never trapped on a
/// splash, and never sees it come back on a later retry either. Desktop is
/// never held. The widget wiring is covered in `main_bootstrap_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/mobile_boot_gate.dart';

void main() {
  group('shouldShowBootSplash', () {
    test('desktop is never covered, whatever the sync state', () {
      expect(
        shouldShowBootSplash(
          isMobile: false,
          synced: false,
          hasFailedSinceLive: false,
        ),
        isFalse,
      );
    });

    test('the resting offline before any attempt still shows the splash', () {
      // No flash of the empty home while offline precedes the first connect.
      expect(
        shouldShowBootSplash(
          isMobile: true,
          synced: false,
          hasFailedSinceLive: false,
        ),
        isTrue,
      );
    });

    test('once the first attempt has failed, the splash stays down through '
        'every later retry', () {
      // The fixed case: a latch, so a later retry's own connecting/offline flip cannot re-arm it.
      expect(
        shouldShowBootSplash(
          isMobile: true,
          synced: false,
          hasFailedSinceLive: true,
        ),
        isFalse,
      );
    });

    test('once the first catch-up lands the home shows for good', () {
      expect(
        shouldShowBootSplash(
          isMobile: true,
          synced: true,
          hasFailedSinceLive: false,
        ),
        isFalse,
      );
    });
  });
}
