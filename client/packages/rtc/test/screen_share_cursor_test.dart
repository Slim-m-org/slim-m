// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The cursor choice reaches the capturer's setting, which it reads when a share starts.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_rtc/rtc.dart';

void main() {
  tearDown(() {
    shareCursorVisible.value = true;
    applyShareCursor();
  });

  test('the cursor is drawn until the user turns it off', () {
    applyShareCursor();
    expect(rtc.Helper.screenCaptureShowCursor, isTrue);
  });

  test('hiding the cursor reaches the capturer setting', () {
    shareCursorVisible.value = false;
    applyShareCursor();
    expect(rtc.Helper.screenCaptureShowCursor, isFalse);
  });
}
