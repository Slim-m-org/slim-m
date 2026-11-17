// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the DM call ring controller knows about the rings in and out of this device.
library;

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

/// Why an outgoing ring ended without anyone joining.
enum OutgoingRingEndReason { noAnswer, declined, doNotDisturb }

/// The last outgoing ring that ended unanswered, so the call screen can say
/// why the call is over rather than that the caller left it.
class OutgoingRingEnd {
  const OutgoingRingEnd({required this.channelId, required this.reason});

  final String channelId;
  final OutgoingRingEndReason reason;
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
    this.lastOutgoingEnd,
  });

  final IncomingDmCallRing? incoming;
  final OutgoingDmCallRing? outgoing;
  final CallKitPhase callKit;
  final OutgoingRingEnd? lastOutgoingEnd;

  /// Whether this device is ringing out from [channelId]'s call right now.
  bool isCallingFrom(String channelId) => outgoing?.channelId == channelId;

  /// Why [channelId]'s last outgoing ring ended unanswered, if it did.
  OutgoingRingEndReason? endedUnansweredIn(String channelId) =>
      lastOutgoingEnd?.channelId == channelId ? lastOutgoingEnd!.reason : null;

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
    OutgoingRingEnd? lastOutgoingEnd,
    bool clearLastOutgoingEnd = false,
  }) => DmCallRingState(
    incoming: clearIncoming ? null : (incoming ?? this.incoming),
    outgoing: clearOutgoing ? null : (outgoing ?? this.outgoing),
    callKit: callKit ?? this.callKit,
    lastOutgoingEnd: clearLastOutgoingEnd
        ? null
        : (lastOutgoingEnd ?? this.lastOutgoingEnd),
  );
}
