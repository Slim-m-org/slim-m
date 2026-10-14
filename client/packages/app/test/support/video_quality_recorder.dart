// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The video quality and audio processing half of a `VoiceSession` fake, in one place so adding to
/// the session does not grow every fake past the file budget.
library;

import 'package:slimm_rtc/rtc.dart';

mixin VideoQualityRecorder {
  ReceiveVideoQuality? lastReceiveVideoQuality;
  CameraQuality? lastCameraQuality;

  void setReceiveVideoQuality(ReceiveVideoQuality quality) =>
      lastReceiveVideoQuality = quality;

  void setCameraQuality(CameraQuality quality) => lastCameraQuality = quality;

  bool? lastEvenOutLoudSounds;

  void setEvenOutLoudSounds(bool enabled) => lastEvenOutLoudSounds = enabled;

  bool? lastStrongNoiseSuppression;

  void setStrongNoiseSuppression(bool enabled) =>
      lastStrongNoiseSuppression = enabled;
}
