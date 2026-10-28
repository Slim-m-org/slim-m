// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Android's screen-capture consent, asked before the foreground service starts.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Android 14 only lets a mediaProjection foreground service start after the
/// user has consented, so the consent is asked here rather than by `getDisplayMedia`.
/// Returns false on a refusal or any plugin failure.
Future<bool> requestScreenCapturePermission() async {
  try {
    return await rtc.Helper.requestCapturePermission();
  } catch (_) {
    return false;
  }
}
