// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The words for each video quality choice, shared by Voice settings and the
/// in-call menus so the two never name one choice differently.
library;

import 'package:slimm_rtc/rtc.dart';

String receiveVideoQualityLabel(ReceiveVideoQuality q) => switch (q) {
  ReceiveVideoQuality.max => 'Max',
  ReceiveVideoQuality.auto => 'Auto',
  ReceiveVideoQuality.balanced => 'Balanced',
  ReceiveVideoQuality.dataSaver => 'Data saver',
};

String cameraQualityLabel(CameraQuality q) => switch (q) {
  CameraQuality.dataSaver => '360p',
  CameraQuality.balanced => '720p',
  CameraQuality.high => '1080p',
};

/// Said under the resolution pick when it is bigger than any screen here, because a share never goes above its source.
String? screenShareSizeNote(ScreenShareResolution picked, int? displayHeight) =>
    displayHeight != null && picked.height > displayHeight
    ? 'Larger than your screen, so it is shared at your screen size.'
    : null;
