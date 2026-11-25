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
  bool microphoneEnabled = true,
}) {
  switch (s) {
    case VoiceSessionState.connecting:
      if (channelId == null) return;
      unawaited(
        lifecycle.callStarted(callId: channelId, displayName: 'Voice call'),
      );
    case VoiceSessionState.connected:
      unawaited(lifecycle.callConnected());
      // A call that joins muted must not show as live in the system call screen.
      if (!microphoneEnabled) unawaited(lifecycle.callMuted(muted: true));
    case VoiceSessionState.idle:
    case VoiceSessionState.failed:
      unawaited(lifecycle.callEnded());
  }
}

/// Keeps the microphone and the system call screen in step: a mute from the lock screen, AirPods or
/// CarPlay reaches the microphone, and a mute in the app reaches the system call screen.
class CallMuteBridge {
  CallMuteBridge(
    this._lifecycle, {
    required bool Function() inCall,
    required bool Function() microphoneEnabled,
    required Future<void> Function() toggleMicrophone,
  }) : _last = microphoneEnabled() {
    _requests = _lifecycle.muteRequests.listen((muted) {
      if (!inCall() || microphoneEnabled() == !muted) return;
      unawaited(toggleMicrophone());
    });
  }

  final CallLifecycleChannel _lifecycle;
  late final StreamSubscription<bool> _requests;
  bool _last;

  /// The app's own microphone state changed; the system call screen is told only when it did.
  void reflect(bool microphoneEnabled) {
    if (microphoneEnabled == _last) return;
    _last = microphoneEnabled;
    unawaited(_lifecycle.callMuted(muted: !microphoneEnabled));
  }

  void dispose() => unawaited(_requests.cancel());
}
