// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The per-channel read markers `GET /read-states` answers in one call.
///
/// Split out of models.dart to stay under this repo's line budget.
library;

import 'models.dart';

/// One channel's [ReadState], as `GET /read-states` lists it for every
/// channel the caller can read.
class ChannelReadState {
  const ChannelReadState({required this.channelId, required this.state});

  final String channelId;
  final ReadState state;

  factory ChannelReadState.fromJson(Map<String, dynamic> json) =>
      ChannelReadState(
        channelId: json['channel_id'] as String,
        state: ReadState.fromJson(json),
      );
}

/// How far a user has read in a channel, and how much is left.
class ReadState {
  const ReadState({
    required this.lastReadSeq,
    required this.unread,
    this.manuallyUnread = false,
  });

  final int lastReadSeq;
  final int unread;

  /// The caller asked to see this channel as unread even though they have
  /// read it. Distinct from [unread], which counts messages: this records an
  /// intention, and the two answer different questions. Defaults false so a
  /// server too old to send it reads as "not marked" rather than failing.
  final bool manuallyUnread;

  factory ReadState.fromJson(Map<String, dynamic> json) => ReadState(
        lastReadSeq: json['last_read_seq'] as int,
        unread: json['unread'] as int,
        manuallyUnread: json['manually_unread'] as bool? ?? false,
      );
}

/// One scope's position, sent when catching up.
class ScopeCursor {
  const ScopeCursor({
    required this.channelId,
    required this.afterSeq,
    this.afterOpSeq,
  });

  final String channelId;
  final int afterSeq;

  /// The message-op cursor, absent when this client holds none.
  ///
  /// Absent is what an older client always sends and what a newer one sends
  /// before it has adopted a head, and both get the same answer: no ops, and
  /// never a reset from an op gap. Sending it is what opts a scope in.
  final int? afterOpSeq;

  Map<String, dynamic> toJson() => {
        'channel_id': channelId,
        'after_seq': afterSeq,
        if (afterOpSeq != null) 'after_op_seq': afterOpSeq,
      };
}

/// What catch-up returned for one scope.
class ScopeDelta {
  const ScopeDelta({
    required this.channelId,
    required this.messages,
    required this.hasMore,
    required this.reset,
    this.ops = const <MessageOp>[],
    this.opLatestSeq,
    this.opsHasMore = false,
  });

  final String channelId;

  /// Oldest first, unlike history, which is newest first.
  final List<Message> messages;

  /// More remains past what this response carried.
  final bool hasMore;

  /// Either cursor was too far behind: drop local state for this scope and
  /// refetch. There is no separate ops flag, because the recovery is the same
  /// either way, and it is only ever set from an op gap for a scope whose
  /// request carried an op cursor.
  final bool reset;

  /// Empty whenever the request carried no op cursor, and empty when there is
  /// genuinely nothing, the convention `reactions` and `attachments` follow.
  final List<MessageOp> ops;

  /// The head of the channel's op stream, and the old-server detector: a
  /// server with no op stream sends no such key, so null means "this
  /// deployment cannot reconcile" rather than "the stream is empty".
  ///
  /// Detection is by field absence rather than through the capability
  /// handshake, which derives its list by probing the router and so can see a
  /// new path but never a new field.
  final int? opLatestSeq;

  /// More ops remain past what this response carried.
  final bool opsHasMore;

  factory ScopeDelta.fromJson(Map<String, dynamic> json) => ScopeDelta(
        channelId: json['channel_id'] as String,
        messages: (json['messages'] as List<dynamic>)
            .map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList(growable: false),
        hasMore: json['has_more'] as bool,
        reset: json['reset'] as bool,
        ops: (json['ops'] as List<dynamic>? ?? const <dynamic>[])
            .map((o) => MessageOp.fromJson(o as Map<String, dynamic>))
            .toList(growable: false),
        opLatestSeq: json['op_latest_seq'] as int?,
        opsHasMore: json['ops_has_more'] as bool? ?? false,
      );
}
