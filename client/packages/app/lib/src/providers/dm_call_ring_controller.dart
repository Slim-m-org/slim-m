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
/// - **Ringing is not gated on quiet hours**, and follows the account's own
///   notification preference the same way an ordinary DM message already
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

import '../routing/router.dart';
import '../routing/routes.dart';
import 'dm_call.dart';
import 'ensure_dm_channel.dart';
import 'live_events.dart';
import 'providers.dart';
import 'voice_controller.dart';

/// An incoming ring this account has not yet answered or declined.
class IncomingDmCallRing {
  const IncomingDmCallRing({
    required this.channelId,
    required this.ringId,
    required this.callerId,
  });

  final String channelId;
  final String ringId;
  final String callerId;
}

/// An outgoing ring this account started, waiting on the other side to
/// answer, decline, or let it time out.
class OutgoingDmCallRing {
  const OutgoingDmCallRing({required this.channelId, required this.ringId});

  final String channelId;
  final String ringId;
}

/// What the system call screen is doing about an incoming call right now.
///
/// CallKit and the websocket announce the same ring separately, and only the
/// websocket says which channel it is, so this is how the two are joined.
enum CallKitPhase { none, ringing, answered }

class DmCallRingState {
  const DmCallRingState({
    this.incoming,
    this.outgoing,
    this.callKit = CallKitPhase.none,
  });

  final IncomingDmCallRing? incoming;
  final OutgoingDmCallRing? outgoing;
  final CallKitPhase callKit;

  /// The ring the in-app overlay should show: none while CallKit is already
  /// ringing for it, since two prompts for one call is the bug this exists for.
  IncomingDmCallRing? get visibleIncoming =>
      callKit == CallKitPhase.none ? incoming : null;

  DmCallRingState copyWith({
    IncomingDmCallRing? incoming,
    bool clearIncoming = false,
    OutgoingDmCallRing? outgoing,
    bool clearOutgoing = false,
    CallKitPhase? callKit,
  }) => DmCallRingState(
    incoming: clearIncoming ? null : (incoming ?? this.incoming),
    outgoing: clearOutgoing ? null : (outgoing ?? this.outgoing),
    callKit: callKit ?? this.callKit,
  );
}

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
    });
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;
  late final StreamSubscription<CallKitIncomingEvent> _callKitSub;
  DateTime? _answeredAt;
  String? _callKitCallId;
  String? _answeredRingId;
  String? _answeredChannelId;

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
    final declined = state.callKit == CallKitPhase.ringing;
    final ring = state.incoming;
    final answeredChannel = _answeredChannelId;
    if (callId == _callKitCallId) _forgetCallKit();
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
    } on Exception {
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

  /// A DM's two participants are the whole audience for its own
  /// `call.ringing`/`call.ring_ended` frames, so the caller's own client
  /// receives both events too; [_onEvent] tells its own ring apart from an
  /// incoming one by comparing `callerId` against this session's own id.
  void _onEvent(api.ServerEvent event) {
    switch (event) {
      case api.CallRinging(:final channelId, :final ringId, :final callerId):
        // Own ring already known from starting it; see this method's own doc.
        final selfId = _ref.read(apiProvider).session.tokens?.userId;
        if (callerId == selfId || ringId == _answeredRingId) return;
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
      case api.CallRingEnded(:final ringId, :final outcome):
        _onRingEnded(ringId, outcome);
      default:
        break;
    }
  }

  /// Clears whichever local ring state [ringId] belongs to. For an outgoing
  /// ring that ended in [api.CallRingOutcome.declined] or
  /// [api.CallRingOutcome.timedOut] - the two outcomes where the callee
  /// never joins - this also hangs up the caller's own call, already
  /// connected while it rang (`dm_call_button.dart`), rather than leaving it
  /// running alone: exactly the resource-waste problem this feature exists
  /// to close. [api.CallRingOutcome.answered] and
  /// [api.CallRingOutcome.canceled] need nothing further here.
  void _onRingEnded(String ringId, api.CallRingOutcome outcome) {
    if (state.incoming?.ringId == ringId) {
      state = state.copyWith(clearIncoming: true, callKit: CallKitPhase.none);
      _endCallKit();
    } else if (ringId == _answeredRingId &&
        outcome != api.CallRingOutcome.answered) {
      _endCallKit();
    }
    final outgoing = state.outgoing;
    if (outgoing != null && outgoing.ringId == ringId) {
      state = state.copyWith(clearOutgoing: true);
      final shouldHangUp =
          outcome == api.CallRingOutcome.declined ||
          outcome == api.CallRingOutcome.timedOut;
      if (shouldHangUp) _hangUpIfStillOn(outgoing.channelId);
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
    try {
      final started = await _ref.read(apiProvider).ringDmCall(channelId);
      state = state.copyWith(
        outgoing: OutgoingDmCallRing(
          channelId: channelId,
          ringId: started.ringId,
        ),
      );
    } on api.ApiException {
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
    } on api.ApiException {
      // Best-effort: this ring times out on the caller's own side regardless.
    }
  }

  /// Forgets any ring state a dropped connection could otherwise leave stuck
  /// forever (an incoming banner nobody can answer, or a caller waiting on a
  /// `call.ring_ended` that will never arrive). [SyncController.start] calls
  /// this on every (re)connect, `DmCallActivityController.clear`'s own shape.
  void clear() {
    if (mounted) state = DmCallRingState(callKit: state.callKit);
  }

  @override
  void dispose() {
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
