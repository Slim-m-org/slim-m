// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_controller.dart';

/// Deciding whether a drop is worth rejoining, and driving the attempts.
///
/// Split out for [VoiceController]'s own 500-line hard ceiling, as a mixin
/// for the reason [VoiceControllerInputMixin] gives. The timer itself lives
/// in [VoiceAutoRejoin]; this is the part that knows what a drop meant and
/// what to do about it.
mixin VoiceControllerRejoinMixin
    on
        StateNotifier<VoiceState>,
        VoiceControllerInputMixin,
        VoiceControllerCallClockMixin {
  /// Bridges to [VoiceController]'s own members, [VoiceControllerInputMixin]'s
  /// own reasoning: the `on` clause, not this file's privacy, is what bounds
  /// what a mixin can reach.
  VoiceAutoRejoin get _rejoinAttempts;
  Future<void> join(String channelId);

  /// The channel of the automatic attempt in flight, so [join] keeps
  /// [VoiceState.rejoining] up for it instead of clearing it as it does for
  /// a person's own join, including one into another channel.
  String? _autoAttemptChannel;

  /// Which SFU-decided drops are an accident rather than a decision.
  ///
  /// A lost connection, or a `removed` that [VoiceController] has already
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
  static bool _rejoinableDrop(VoiceDisconnect dropped) =>
      dropped == VoiceDisconnect.connectionLost ||
      dropped == VoiceDisconnect.heartbeatLagEviction;

  /// Marks the call failed for an SFU-decided drop, and queues a rejoin when the drop was an accident.
  void _endCallForDrop(VoiceDisconnect dropped) {
    // Read before the copyWith clears it: only a connected call is one to put back.
    final rejoinable = _rejoinableDrop(dropped);
    final wasConnected = _callClock.hold(
      state.connectedAt,
      rejoinable: rejoinable,
    );
    state = state.copyWith(
      state: VoiceSessionState.failed,
      error: dropped.message,
      clearConnectedAt: true,
    );
    final channelId = state.channelId;
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
    final queued = _rejoinAttempts.schedule(
      () => unawaited(_attemptAutoRejoin(channelId)),
    );
    state = state.copyWith(rejoining: queued);
  }

  /// Retries at once when the websocket comes back, keeping the timer as the
  /// fallback: the socket returning is the first sign the network is usable,
  /// and waiting out a 30s tail after that strands the call.
  void _watchSyncForRejoin() {
    _rejoinAttempts.watchSync(_inputRef, () {
      final channelId = state.channelId;
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
    if (state.channelId != channelId) return;
    _autoAttemptChannel = channelId;
    try {
      await join(channelId);
    } finally {
      _autoAttemptChannel = null;
    }
    if (state.channelId != channelId) return;
    if (state.state == VoiceSessionState.connected) return;
    // A refusal that cannot change (forbidden, no voice, insecure SFU) is the person's to act on.
    if (!state.retryable) {
      state = state.copyWith(rejoining: false);
      return;
    }
    _scheduleAutoRejoin(channelId);
  }
}
