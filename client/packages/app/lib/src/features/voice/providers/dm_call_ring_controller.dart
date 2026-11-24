// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ringing the other side of a DM call, and reacting to an incoming ring,
/// an answer, a decline, or a timeout.
///
/// Three choices this feature makes, stated here rather than left implicit:
///
/// - **The ring timeout is entirely server-owned** (`voice::ring::RING_TIMEOUT`
///   in `crates/slimm-server`, 30 seconds today). This controller never runs
///   its own client-side timer; it only reacts to the `call.ring_ended` frame
///   the server publishes once its own timeout fires, so the caller's own
///   call is torn down by the same authority that decided the ring was over,
///   never by a client clock that could drift from it.
/// - **A missed or declined call leaves no trace in the conversation.**
///   No system message is written, so this feature needed no migration and
///   adds no new moderation surface; a transcript of who called whom is a
///   deliberate absence, not an oversight.
/// - **Do not disturb blocks a ring outright**, on the server, so it never
///   reaches this controller. Quiet hours do not; ringing follows the
///   account's own notification preference the same way an ordinary DM message already
///   does: a `nothing` preference silences it, `mentions`/`everything` both
///   let it through, since a DM already counts as addressed to that account
///   either way. See `push::call_ring`'s own module doc on the server for
///   why quiet hours structurally cannot narrow that further.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../../routing/router.dart';
import '../../../routing/routes.dart';
import 'dm_call.dart';
import '../../channels/providers/ensure_dm_channel.dart';
import '../../members/providers/blocks_controller.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import 'dm_call_ring_reconnect.dart';
import 'dm_call_ring_state.dart';
import 'voice_controller.dart';

export 'dm_call_ring_state.dart';

class DmCallRingController extends StateNotifier<DmCallRingState> {
  DmCallRingController(this._ref) : super(const DmCallRingState()) {
    _sub = _ref.read(liveEventsProvider).listen(_onEvent);
    final callKit = _ref.read(callKitIncomingChannelProvider);
    _callKitSub = callKit.events.listen(_onCallKit);
    unawaited(
      callKit.takePending().then((pending) => pending.forEach(_onCallKit)),
    );
    _ref.listen<String?>(voiceControllerProvider.select((s) => s.channelId), (
      previous,
      next,
    ) {
      if (previous != null && next == null && _answeredRingId != null) {
        _endCallKit();
      }
      if (next != null) _forgetLastOutgoingEnd(next);
    });
    // Only a join that connected answers the ring; one that fails leaves it to answer.
    _ref.listen<String?>(
      voiceControllerProvider.select(
        (s) => s.state == VoiceSessionState.connected ? s.channelId : null,
      ),
      (_, next) {
        if (next != null) _joinedCall(next);
      },
    );
    _ref.listen<VoiceState>(voiceControllerProvider, (_, _) {
      _reconnect.settleOutgoing(stillCalling: _stillCalling);
    });
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;
  late final StreamSubscription<CallKitIncomingEvent> _callKitSub;
  DateTime? _answeredAt;
  String? _callKitCallId;
  String? _answeredRingId;
  String? _answeredChannelId;

  late final _reconnect = DmCallRingReconnect(
    DmCallRingReconnectHost(
      read: () => state,
      write: (next) => state = next,
      isMounted: () => mounted,
      listIncoming: () => _ref.read(apiProvider).listIncomingDmCallRings(),
      restorable: _restorable,
      dropIncoming: _dropIncoming,
      loadChannel: (channelId) => unawaited(ensureChannelLoaded(channelId)),
    ),
    ringTimeout: _answerWindow,
  );

  /// Rings that ended recently, so one that ends before its own start
  /// response lands is not mistaken for still ringing.
  final _endedRings = <String, api.CallOutcome>{};
  static const _endedRingsKept = 16;

  /// How long an answer waits for its `call.ringing` frame: the server's own
  /// ring timeout, past which no frame for that call can still come.
  static const _answerWindow = Duration(seconds: 30);

  bool get _answerIsFresh {
    final at = _answeredAt;
    return state.callKit == CallKitPhase.answered &&
        at != null &&
        DateTime.now().difference(at) < _answerWindow;
  }

  void _onCallKit(CallKitIncomingEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case CallKitIncomingKind.ringing:
        _callKitCallId = event.callId;
        if (state.callKit == CallKitPhase.none) {
          state = state.copyWith(callKit: CallKitPhase.ringing);
        }
      case CallKitIncomingKind.answered:
        _callKitCallId = event.callId;
        final ring = state.incoming;
        _answeredAt = DateTime.now();
        state = state.copyWith(callKit: CallKitPhase.answered);
        if (ring != null) {
          unawaited(_answerFromCallKit(ring));
        } else {
          unawaited(_answerFromOutstandingRing(event.callId));
        }
      case CallKitIncomingKind.ended:
        _onCallKitEnded(event.callId);
    }
  }

  void _onCallKitEnded(String callId) {
    if (callId != _callKitCallId) return;
    final declined = state.callKit == CallKitPhase.ringing;
    final ring = state.incoming;
    final answeredChannel = _answeredChannelId;
    _forgetCallKit();
    state = state.copyWith(callKit: CallKitPhase.none);
    if (declined && ring != null) unawaited(decline(ring));
    if (!declined && answeredChannel != null) _hangUpIfStillOn(answeredChannel);
  }

  /// A cold launch answers before the websocket connects, so the
  /// `call.ringing` frame is long gone: ask the server which ring is still
  /// outstanding. None means it timed out or was cancelled, and the system
  /// call is ended rather than left up with nothing behind it.
  Future<void> _answerFromOutstandingRing(String callId) async {
    final List<api.OutstandingDmCallRing> rings;
    try {
      rings = await _ref.read(apiProvider).listIncomingDmCallRings();
    } on Exception catch (error, stack) {
      api.reportFailure(
        api.LogTag.voice,
        'look up the call that is ringing',
        error,
        stack,
      );
      // Unknown, not empty: the websocket frame can still answer it.
      return;
    }
    final stillWaiting =
        mounted &&
        _callKitCallId == callId &&
        state.callKit == CallKitPhase.answered;
    if (!stillWaiting) return;
    if (rings.isEmpty) {
      state = state.copyWith(callKit: CallKitPhase.none);
      _endCallKit();
      return;
    }
    final outstanding = rings.first;
    final ring = IncomingDmCallRing(
      channelId: outstanding.channelId,
      ringId: outstanding.ringId,
      callerId: outstanding.callerId,
    );
    state = state.copyWith(incoming: ring);
    await _answerFromCallKit(ring);
  }

  /// The answer happened on the system call screen, so the ring is consumed
  /// here and the call joined without asking again.
  Future<void> _answerFromCallKit(IncomingDmCallRing ring) async {
    _answeredRingId = ring.ringId;
    _answeredChannelId = ring.channelId;
    state = state.copyWith(callKit: CallKitPhase.none);
    await accept(ring);
    if (!mounted) return;
    await _ref.read(voiceControllerProvider.notifier).join(ring.channelId);
    if (!mounted) return;
    final joined = _ref.read(voiceControllerProvider).channelId;
    if (joined != ring.channelId) _endCallKit();
  }

  void _forgetCallKit() {
    _callKitCallId = null;
    _answeredRingId = null;
    _answeredChannelId = null;
  }

  void _endCallKit() {
    final id = _callKitCallId;
    _forgetCallKit();
    if (id != null) {
      unawaited(_ref.read(callKitIncomingChannelProvider).endCall(id));
    }
  }

  /// This device is in [channelId]'s call now: a ring for it is answered here,
  /// on the system call screen too, and an earlier unanswered ring is old news.
  void _joinedCall(String channelId) {
    if (state.incoming?.channelId == channelId) _dropIncoming();
  }

  void _forgetLastOutgoingEnd(String channelId) {
    if (state.lastOutgoingEnd?.channelId == channelId) {
      state = state.copyWith(clearLastOutgoingEnd: true);
    }
  }

  /// `call.ringing` reaches only the callees, but a server older than that
  /// also sent it to the caller, so [_onEvent] still skips its own ring.
  void _onEvent(api.ServerEvent event) {
    switch (event) {
      case api.CallRinging(:final channelId, :final ringId, :final callerId):
        final selfId = _ref.read(apiProvider).session.tokens?.userId;
        if (callerId == selfId || ringId == _answeredRingId) return;
        if (_isBlocked(callerId)) return;
        final inThatCall =
            _ref.read(voiceControllerProvider).channelId == channelId;
        if (inThatCall && !_answerIsFresh) return;
        final ring = IncomingDmCallRing(
          channelId: channelId,
          ringId: ringId,
          callerId: callerId,
        );
        final stale = state.callKit == CallKitPhase.answered && !_answerIsFresh;
        state = state.copyWith(
          incoming: ring,
          callKit: stale ? CallKitPhase.none : null,
        );
        if (_answerIsFresh) {
          unawaited(_answerFromCallKit(ring));
        } else {
          unawaited(ensureChannelLoaded(channelId));
        }
      case api.CallRingEnded(:final channelId, :final ringId, :final outcome):
        _onRingEnded(channelId, ringId, outcome);
      default:
        break;
    }
  }

  /// Clears whichever local ring state [ringId] belongs to. For an outgoing
  /// ring that ended in [api.CallOutcome.declined] or
  /// [api.CallOutcome.timedOut] - the two outcomes where the callee
  /// never joins - this also hangs up the caller's own call, already
  /// connected while it rang (`dm_call_button.dart`), rather than leaving it
  /// running alone: exactly the resource-waste problem this feature exists
  /// to close. [api.CallOutcome.answered] and
  /// [api.CallOutcome.canceled] need nothing further here.
  void _onRingEnded(String channelId, String ringId, api.CallOutcome outcome) {
    _rememberEnded(ringId, outcome);
    final lastEnd = state.lastOutgoingEnd;
    if (outcome == api.CallOutcome.answered &&
        lastEnd?.channelId == channelId &&
        lastEnd?.ringId != ringId) {
      state = state.copyWith(clearLastOutgoingEnd: true);
    }
    if (state.incoming?.ringId == ringId) {
      state = state.copyWith(clearIncoming: true, callKit: CallKitPhase.none);
      _endCallKit();
    } else if (ringId == _answeredRingId &&
        outcome != api.CallOutcome.answered) {
      _endCallKit();
    }
    final outgoing = state.outgoing;
    if (outgoing != null && outgoing.ringId == ringId) {
      state = state.copyWith(clearOutgoing: true);
      _hangUpIfNobodyJoined(outgoing.channelId, ringId, outcome);
    }
  }

  void _hangUpIfNobodyJoined(
    String channelId,
    String ringId,
    api.CallOutcome outcome, {
    bool doNotDisturb = false,
  }) {
    final reason = switch (outcome) {
      api.CallOutcome.declined => OutgoingRingEndReason.declined,
      api.CallOutcome.timedOut when doNotDisturb =>
        OutgoingRingEndReason.doNotDisturb,
      api.CallOutcome.timedOut => OutgoingRingEndReason.noAnswer,
      _ => null,
    };
    if (reason == null || _someoneElseIsIn(channelId)) return;
    state = state.copyWith(
      lastOutgoingEnd: OutgoingRingEnd(
        channelId: channelId,
        ringId: ringId,
        reason: reason,
      ),
    );
    _hangUpIfStillOn(channelId);
  }

  /// A ring can end unanswered on a call that is live anyway, say one joined
  /// through a server older than the one that ends such a ring as answered.
  bool _someoneElseIsIn(String channelId) {
    final voice = _ref.read(voiceControllerProvider);
    return voice.channelId == channelId &&
        voice.participants.any((participant) => !participant.isLocal);
  }

  void _rememberEnded(String ringId, api.CallOutcome outcome) {
    _endedRings[ringId] = outcome;
    if (_endedRings.length > _endedRingsKept) {
      _endedRings.remove(_endedRings.keys.first);
    }
  }

  void _hangUpIfStillOn(String channelId) {
    final voice = _ref.read(voiceControllerProvider);
    if (voice.channelId == channelId) {
      unawaited(_ref.read(voiceControllerProvider.notifier).leave());
    }
  }

  /// Starts ringing the other side of [channelId]'s call.
  ///
  /// Best-effort: a failure here means the callee's device is never told,
  /// but the caller's own call - already joined by the time this runs, see
  /// `dm_call_button.dart` - proceeds regardless, exactly as every call did
  /// before ringing existed. There is nothing durable to retry, and no
  /// persistent error state worth surfacing for a signal this transient.
  Future<void> startOutgoingRing(String channelId) async {
    if (state.lastOutgoingEnd?.channelId == channelId) {
      state = state.copyWith(clearLastOutgoingEnd: true);
    }
    try {
      final started = await _ref.read(apiProvider).ringDmCall(channelId);
      if (!mounted) return;
      final everyoneOnDnd =
          started.timeoutMs == 0 && started.doNotDisturb.isNotEmpty;
      if (everyoneOnDnd) {
        _hangUpIfNobodyJoined(
          channelId,
          started.ringId,
          api.CallOutcome.timedOut,
          doNotDisturb: true,
        );
        return;
      }
      final endedAs = _endedRings[started.ringId];
      if (endedAs != null) {
        _hangUpIfNobodyJoined(channelId, started.ringId, endedAs);
        return;
      }
      state = state.copyWith(
        outgoing: OutgoingDmCallRing(
          channelId: channelId,
          ringId: started.ringId,
        ),
      );
    } on api.ApiException catch (error, stack) {
      api.reportFailure(
        api.LogTag.voice,
        'ring the other person',
        error,
        stack,
      );
      // Best-effort; see this method's own doc.
    }
  }

  /// Clears the incoming ring without declining it - the accept path, whose
  /// actual "answer" is the callee's own call join a moment later (a
  /// heartbeat is what the server treats as answering; see `voice/ring.rs`'s
  /// own doc for why there is no separate accept route to call here).
  void dismissIncoming() {
    if (mounted) state = state.copyWith(clearIncoming: true);
  }

  /// The DM must be in the local store before anything routes to it.
  @visibleForTesting
  Future<void> ensureChannelLoaded(String channelId) =>
      ensureDmChannelLoaded(_ref, channelId);

  /// Accepts an incoming ring: opens the DM's call pane and navigates there.
  Future<void> accept(IncomingDmCallRing ring) async {
    dismissIncoming();
    await ensureChannelLoaded(ring.channelId);
    if (!mounted) return;
    _ref.read(dmCallOpenProvider.notifier).state = ring.channelId;
    _ref.read(routerProvider).go(Routes.channel(ring.channelId));
  }

  /// Declines an incoming ring.
  Future<void> decline(IncomingDmCallRing ring) async {
    dismissIncoming();
    try {
      await _ref.read(apiProvider).declineDmCallRing(ring.channelId);
    } on api.ApiException catch (error, stack) {
      api.reportFailure(api.LogTag.voice, 'decline the call', error, stack);
      // Best-effort: this ring times out on the caller's own side regardless.
    }
  }

  /// Forgets every ring, for a session that ended.
  void clear() {
    if (!mounted) return;
    _reconnect.forget();
    state = DmCallRingState(
      callKit: state.callKit,
      lastOutgoingEnd: state.lastOutgoingEnd,
    );
  }

  /// Keeps both rings across a reconnect; see [DmCallRingReconnect].
  /// [SyncController.start] calls this on every (re)connect.
  void holdForReconnect() {
    if (mounted) _reconnect.hold();
  }

  /// Reads back the rings still waiting on this account once the socket is
  /// live: a `call.ringing` frame sent while it was down is never replayed.
  Future<void> restoreAfterLive() => _reconnect.settleIncoming();

  bool _restorable(api.OutstandingDmCallRing ring) {
    final selfId = _ref.read(apiProvider).session.tokens?.userId;
    final inThatCall =
        _ref.read(voiceControllerProvider).channelId == ring.channelId;
    return ring.callerId != selfId &&
        ring.ringId != _answeredRingId &&
        !_endedRings.containsKey(ring.ringId) &&
        !_isBlocked(ring.callerId) &&
        !inThatCall &&
        !_answerIsFresh;
  }

  bool _watchingBlocks = false;

  /// Read once the signed-in shell has loaded the list; a block drops the ring at once.
  bool _isBlocked(String userId) {
    if (!_ref.exists(blocksProvider)) return false;
    if (!_watchingBlocks) {
      _watchingBlocks = true;
      _ref.listen<BlocksState>(blocksProvider, (_, next) {
        if (next.contains(state.incoming?.callerId)) _dropIncoming();
      });
    }
    return _ref.read(blocksProvider).contains(userId);
  }

  bool _stillCalling(String channelId) {
    final voice = _ref.read(voiceControllerProvider);
    return voice.channelId == channelId &&
        voice.state != VoiceSessionState.failed &&
        !_someoneElseIsIn(channelId);
  }

  void _dropIncoming() {
    final callKitRinging = state.callKit == CallKitPhase.ringing;
    state = state.copyWith(
      clearIncoming: true,
      callKit: callKitRinging ? CallKitPhase.none : null,
    );
    if (callKitRinging) _endCallKit();
  }

  @override
  void dispose() {
    _reconnect.forget();
    unawaited(_sub.cancel());
    unawaited(_callKitSub.cancel());
    super.dispose();
  }
}

/// The platform seam, overridable in tests.
final callKitIncomingChannelProvider = Provider<CallKitIncomingChannel>((ref) {
  final channel = CallKitIncomingChannel();
  ref.onDispose(channel.dispose);
  return channel;
});

final dmCallRingControllerProvider =
    StateNotifierProvider<DmCallRingController, DmCallRingState>(
      (ref) => DmCallRingController(ref),
    );
