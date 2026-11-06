// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How tall a camera's frames really came in, against what was asked of it.
///
/// Desktop libwebrtc lists no camera formats, so the only honest answer to
/// "can this camera do 1080p" is the first frame of a capture that asked for
/// it. Nothing opens a camera to find out; a call that turned it on anyway does.
library;

import 'package:flutter/foundation.dart';

/// One camera start: which camera (empty for the platform default), the
/// height asked for, and the height its first frame had.
typedef CameraReachReading = ({String deviceId, int asked, int delivered});

/// The latest camera start's reading; null until a camera has been measured.
///
/// Process-wide like `localShareCapturedSize`, so the test doubles that
/// implement `VoiceSession` need nothing new.
final localCameraReach = ValueNotifier<CameraReachReading?>(null);

/// The tallest camera quality known to work after [reading], given what was
/// known before ([known], for [knownDevice]); null means nothing rules any out.
///
/// A short frame sets the ceiling. A frame as tall as asked clears a ceiling
/// learned from another camera, or one this camera has now beaten, so a better
/// webcam is never kept from the choice that would show it is better.
({String deviceId, int height})? nextCameraReach({
  required ({String deviceId, int height})? known,
  required CameraReachReading reading,
}) {
  if (reading.delivered < reading.asked) {
    return (deviceId: reading.deviceId, height: reading.delivered);
  }
  if (known == null) return null;
  if (known.deviceId != reading.deviceId) return null;
  if (reading.delivered > known.height) return null;
  return known;
}
