// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_auto_rejoin.dart';
import 'voice_call_clock.dart';
import 'voice_state.dart';
import 'voice_state_access.dart';

/// Deciding whether a drop is worth rejoining, and driving the attempts.
///
/// The timer itself lives in [VoiceAutoRejoin]; this is the part that knows
/// what a drop meant and what to do about it.
class VoiceRejoin {
  VoiceRejoin(
    this._access,
    this._attempts,
    this._callClock,
    this._ref,
    this._join,
  );

  final VoiceStateAccess _access;
  final VoiceAutoRejoin _attempts;
  final VoiceCallClock _callClock;
  final Ref _ref;
  final Future<void> Function(String channelId) _join;

  VoiceState get _current => _access.state;

  /// The channel of the automatic attempt in flight, so [join] keeps
  /// [VoiceState.rejoining] up for it instead of clearing it as it does for
  /// a person's own join, including one into another channel.
  String? autoAttemptChannel;

  /// Which SFU-decided drops are an accident rather than a decision.
  ///
  /// A lost connection, or a `removed` that the controller has already
  /// reclassified as [VoiceDisconnect.heartbeatLagEviction] because this
  /// client's own heartbeat was failing when it arrived - that is the
  /// server's stale-call sweep, not somebody's choice, and is exactly the
  /// case this project's own stale-heartbeat sweep is known to reach when a
  /// transport blip crosses `STALE_AFTER` before it clears.
  /// [VoiceDisconnect.replacedByOtherDevice] means this same account
  /// answered somewhere else, and rejoining would have two devices of one
  /// person fighting over the room. A plain [VoiceDisconnect.removed] means
  /// the server took this participant out for some other reason, which is an
  /// answer, not a question. Rejoining either would be overriding somebody.
  static bool rejoinableDrop(VoiceDisconnect dropped) =>
      dropped == VoiceDisconnect.connectionLost ||
      dropped == VoiceDisconnect.heartbeatLagEviction;

  /// Marks the call failed for an SFU-decided drop, and queues a rejoin when the drop was an accident.
  void endCallForDrop(VoiceDisconnect dropped) {
    // Read before the copyWith clears it: only a connected call is one to put back.
    final rejoinable = rejoinableDrop(dropped);
    final wasConnected = _callClock.hold(
      _current.connectedAt,
      rejoinable: rejoinable,
    );
    _access.state = _current.copyWith(
      state: VoiceSessionState.failed,
      error: dropped.message,
      clearConnectedAt: true,
    );
    final channelId = _current.channelId;
    if (wasConnected && rejoinable && channelId != null) {
      _scheduleAutoRejoin(channelId);
    }
  }

  /// Queues the next attempt and records whether there was one to queue, so
  /// [VoiceState.rejoining] is true exactly while an attempt is pending or in
  /// flight and false the moment the budget runs out - which is when the
  /// manual "Try again" becomes the honest thing to show.
  void _scheduleAutoRejoin(String channelId) {
    _watchSyncForRejoin();
    final queued = _attempts.schedule(
      () => unawaited(_attemptAutoRejoin(channelId)),
    );
    _access.state = _current.copyWith(rejoining: queued);
  }

  /// Retries at once when the websocket comes back, keeping the timer as the
  /// fallback: the socket returning is the first sign the network is usable,
  /// and waiting out a 30s tail after that strands the call.
  void _watchSyncForRejoin() {
    _attempts.watchSync(_ref, () {
      final channelId = _current.channelId;
      if (channelId != null) unawaited(_attemptAutoRejoin(channelId));
    });
  }

  /// One attempt, and the decision about the next one.
  ///
  /// Chained from its own outcome rather than from the session's state
  /// stream, because the common failure here never reaches that stream: with
  /// the network still down, [join] fails on the `/voice/token` request and
  /// sets [VoiceSessionState.failed] itself, without the SFU ever having been
  /// contacted to drop us.
  Future<void> _attemptAutoRejoin(String channelId) async {
    // A hang-up or another channel already moved on; this attempt is not about that call.
    if (_current.channelId != channelId) return;
    autoAttemptChannel = channelId;
    try {
      await _join(channelId);
    } finally {
      autoAttemptChannel = null;
    }
    if (_current.channelId != channelId) return;
    if (_current.state == VoiceSessionState.connected) return;
    // A refusal that cannot change (forbidden, no voice, insecure SFU) is the person's to act on.
    if (!_current.retryable) {
      _access.state = _current.copyWith(rejoining: false);
      return;
    }
    _scheduleAutoRejoin(channelId);
  }
}
