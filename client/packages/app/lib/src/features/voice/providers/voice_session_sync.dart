// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the session's state stream drives the call state: the lifecycle report, the heartbeat, the clock and a drop's rejoin.
library;

import 'dart:async';

import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'call_foreground_keeper.dart';
import 'voice_auto_rejoin.dart';
import 'voice_call_clock.dart';
import 'voice_call_heartbeat.dart';
import 'voice_call_lifecycle_report.dart';
import 'voice_camera_hiding.dart';
import 'voice_input_settings.dart';
import 'voice_rejoin.dart';
import 'voice_state.dart';
import 'voice_state_access.dart';

class VoiceSessionSync {
  VoiceSessionSync({
    required this.session,
    required this.access,
    required this.callLifecycle,
    required this.foreground,
    required this.heartbeat,
    required this.autoRejoin,
    required this.callClock,
    required this.rejoin,
    required this.input,
    required this.cameras,
    required this.log,
  });

  final VoiceSession session;
  final VoiceStateAccess access;
  final CallLifecycleChannel callLifecycle;
  final CallForegroundKeeper foreground;
  final VoiceCallHeartbeat heartbeat;
  final VoiceAutoRejoin autoRejoin;
  final VoiceCallClock callClock;
  final VoiceRejoin rejoin;
  final VoiceInputSettings input;
  final VoiceCameraHiding cameras;
  final void Function(String message, {Object? detail}) log;

  VoiceState get _current => access.state;

  /// Applies one session state change to the call state, starting or stopping what depends on a live call.
  void onSessionState(VoiceSessionState s) {
    reportCallLifecycle(callLifecycle, s, channelId: _current.channelId);
    foreground.sessionState(s);
    final dropped = _classifiedDisconnect();
    if (s == VoiceSessionState.failed && dropped != null) {
      heartbeat.stop();
      input.stopWatchingSpaceNoiseSuppression();
      log('The call ended: ${dropped.name}', detail: dropped.message);
      rejoin.endCallForDrop(dropped);
      return;
    }
    _syncHeartbeat(s);
    // The clock starts at the connected transition only; see VoiceCallClock.
    access.state = switch (s) {
      VoiceSessionState.connected when _current.connectedAt == null =>
        _current.copyWith(state: s, connectedAt: callClock.beginHere()),
      VoiceSessionState.idle || VoiceSessionState.failed => _current.copyWith(
        state: s,
        clearConnectedAt: true,
      ),
      _ => _current.copyWith(state: s),
    };
    if (s == VoiceSessionState.connected) {
      cameras.pushBlocked();
      unawaited(callClock.adoptServerStart(access));
    }
  }

  /// A drop the SFU decided on: the reason is the only thing that can tell
  /// "you joined elsewhere" from "your network went". A `removed` that
  /// arrives while this client's own heartbeat has been failing is far
  /// more likely the server's stale-heartbeat sweep than a moderator.
  VoiceDisconnect? _classifiedDisconnect() {
    final raw = session.lastDisconnect;
    final lagging = raw == VoiceDisconnect.removed && heartbeat.isLagging;
    return lagging ? VoiceDisconnect.heartbeatLagEviction : raw;
  }

  void _syncHeartbeat(VoiceSessionState s) {
    switch (s) {
      case VoiceSessionState.connected:
        // Not gated on lifecycle: only termination may let this lapse.
        heartbeat.start(_current.channelId);
        input.watchSpaceNoiseSuppression();
        autoRejoin.connected();
        if (_current.rejoining) {
          access.state = _current.copyWith(rejoining: false);
        }
      case VoiceSessionState.idle:
      case VoiceSessionState.failed:
        heartbeat.stop();
        input.stopWatchingSpaceNoiseSuppression();
      default:
        break;
    }
  }
}
