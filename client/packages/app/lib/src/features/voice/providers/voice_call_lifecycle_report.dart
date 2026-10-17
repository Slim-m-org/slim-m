// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reporting a call's start, connection and end to CallKit, split out of
/// `voice_controller.dart` to make room there for the camera-control
/// additions the file's own review budget would not otherwise fit.
library;

import 'dart:async';

import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

/// Reports this call's start, connection and end to CallKit on iOS; a no-op
/// everywhere else. Keyed off [VoiceSession]'s own state transitions rather
/// than a second copy of the join/leave call sites, so every path that
/// reaches `connecting`, `connected`, `idle` or `failed` - including an
/// SFU-initiated drop - reports the same way.
void reportCallLifecycle(
  CallLifecycleChannel lifecycle,
  VoiceSessionState s, {
  required String? channelId,
}) {
  switch (s) {
    case VoiceSessionState.connecting:
      if (channelId == null) return;
      unawaited(
        lifecycle.callStarted(callId: channelId, displayName: 'Voice call'),
      );
    case VoiceSessionState.connected:
      unawaited(lifecycle.callConnected());
    case VoiceSessionState.idle:
    case VoiceSessionState.failed:
      unawaited(lifecycle.callEnded());
  }
}
