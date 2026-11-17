// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Waits for what just changed to reach the screen before slow work starts.
///
/// On Linux the UI and the platform thread are one, and a sound player's
/// GStreamer setup runs on it: started in the same turn as a call connecting,
/// it held the connecting screen up while the call was already playing.
library;

import 'package:flutter/scheduler.dart';

/// Resolves once the frame after the next one is built, so the next one has
/// been drawn, or after [limit] when no frame comes (a hidden window draws none).
Future<void> afterNextFrameShown({
  Duration limit = const Duration(milliseconds: 250),
}) {
  final scheduler = SchedulerBinding.instance;
  Future<void> twoFrames() async {
    await scheduler.endOfFrame;
    await scheduler.endOfFrame;
  }

  return twoFrames().timeout(limit, onTimeout: () {});
}
