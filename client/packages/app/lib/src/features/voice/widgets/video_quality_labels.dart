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

/// One sentence on what the pick changes, said under the Watching row.
String receiveVideoQualityNote(ReceiveVideoQuality q) => switch (q) {
  ReceiveVideoQuality.max =>
    'Always the sharpest video, whatever the tile size.',
  ReceiveVideoQuality.auto =>
    'Sharpness follows tile size and your connection.',
  ReceiveVideoQuality.balanced =>
    'Cameras use a medium layer; screens stay sharp.',
  ReceiveVideoQuality.dataSaver => 'The smallest layer that still reads.',
};

String cameraQualityLabel(CameraQuality q) => switch (q) {
  CameraQuality.dataSaver => '360p',
  CameraQuality.balanced => '720p',
  CameraQuality.high => '1080p',
};
