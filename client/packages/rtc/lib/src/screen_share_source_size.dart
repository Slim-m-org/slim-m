// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading how big the captured screen really is.
///
/// Capture constraints only ask; the platform delivers the source's own size
/// when it is smaller, and `getSettings` is not implemented on desktop, so the
/// first decoded frame is the one answer that works everywhere.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// The size of the screen the local share captures, once its first frame is read; null when not sharing.
///
/// A process-wide notifier rather than a `VoiceSession` member, so the many test doubles that implement `VoiceSession` stay valid.
final localShareCapturedSize = ValueNotifier<({int width, int height})?>(null);

/// The width and height of [stream]'s first video frame, or null when none
/// arrives within [timeout].
Future<({int width, int height})?> measureCapturedSize(
  rtc.MediaStream stream, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final renderer = rtc.RTCVideoRenderer();
  try {
    await renderer.initialize();
    renderer.srcObject = stream;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (renderer.videoWidth > 0 && renderer.videoHeight > 0) {
        return (width: renderer.videoWidth, height: renderer.videoHeight);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  } finally {
    renderer.srcObject = null;
    await renderer.dispose();
  }
}
