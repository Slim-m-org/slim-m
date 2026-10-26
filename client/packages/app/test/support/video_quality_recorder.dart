// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The video quality and audio processing half of a `VoiceSession` fake, in one place so adding to
/// the session does not grow every fake past the file budget.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:slimm_rtc/rtc.dart';

mixin VideoQualityRecorder {
  CallStatsSampler callStats = CallStatsSampler(targets: () => const []);

  VoiceHealth health = VoiceHealth();

  ValueNotifier<Map<String, VideoTileHealth>> videoHealth = ValueNotifier(
    const {},
  );

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

  bool? lastKeepMicReady;
  bool? lastAppBackgrounded;

  Future<void> setKeepMicReady(bool keepReady) async =>
      lastKeepMicReady = keepReady;

  void setAppBackgrounded(bool backgrounded) =>
      lastAppBackgrounded = backgrounded;

  MicStatus micStatus = MicStatus.ok;
  final micStatusChanges = StreamController<MicStatus>.broadcast();
  int microphoneResets = 0;
  bool microphoneResetWorks = true;

  Stream<MicStatus> get micStatuses => micStatusChanges.stream;

  String? audioInputInUse;

  MicFailureReason? micFailure;
  final micFailureChanges = StreamController<MicFailureReason?>.broadcast();

  Stream<MicFailureReason?> get micFailures => micFailureChanges.stream;

  /// The speaker the test says playback is routed to.
  String? audioOutputInUse;

  bool? lastMicFallbackEnabled;
  String? micFallbackNotice;
  final micFallbackNoticeChanges = StreamController<String?>.broadcast();

  Stream<String?> get micFallbackNotices => micFallbackNoticeChanges.stream;

  void setMicFallbackEnabled(bool enabled) => lastMicFallbackEnabled = enabled;

  void dismissMicFallbackNotice() {
    micFallbackNotice = null;
    micFallbackNoticeChanges.add(null);
  }

  Future<bool> resetMicrophone() async {
    microphoneResets++;
    return microphoneResetWorks;
  }
}
