// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Builds one stored message's row for the transcript: its grouping, day
/// break and callbacks, resolved against the neighbours around it.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_data/data.dart';

import '../providers/message_extras.dart' show MessageExtras;
import 'edit_history_sheet.dart';
import 'message_row.dart';
import 'message_row_callbacks.dart';
import 'message_row_identity.dart';
import 'message_transcript.dart';
import 'message_transcript_dividers.dart';

/// The stored messages around one row; a private answer between breaks the run.
class TranscriptNeighbours {
  const TranscriptNeighbours({
    required this.previous,
    required this.next,
    required this.above,
  });

  final Message? previous;
  final Message? next;
  final Message? above;
}

Widget transcriptMessageRow(
  BuildContext context,
  MessageTranscript transcript,
  Message message,
  TranscriptNeighbours n, {
  required Map<String, Message> byId,
  required MessageExtras extras,
  required bool editing,
  required ({String? previous, String? next}) webhooks,
}) {
  final newDay = isNewDay(
    message,
    n.above,
    historyKnown: transcript.historyKnown,
  );
  return MessageRow(
    message: message,
    // A new day breaks a group so a continuation across midnight regains its avatar and header.
    grouped:
        isGrouped(
          message,
          n.previous,
          webhookUsername: extras.webhookUsername,
          previousWebhookUsername: webhooks.previous,
        ) &&
        !newDay,
    showNewDivider: startsUnread(
      message,
      n.above,
      transcript.lastReadSeq,
      transcript.selfId,
    ),
    groupContinues: _groupContinues(
      transcript,
      message,
      n.next,
      extras,
      webhooks.next,
    ),
    dayLabel: newDay ? formatMessageDay(message.createdAt) : null,
    knownUsernames: transcript.knownUsernames,
    knownRoleNames: transcript.knownRoleNames,
    customEmoji: transcript.customEmoji,
    callbacks: transcriptRowCallbacks(context, transcript, message),
    extras: extras,
    viewerIsCaller:
        extras.call?.callerId != null &&
        extras.call?.callerId == transcript.selfId,
    // A null replyToId is a null map key here, which is a null lookup - the same "no parent" the row renders as nothing.
    replyTo: byId[message.replyToId],
    replyParentAdjacent: message.replyToId == n.previous?.id,
    editing: editing,
    actions: transcript.actionsFor(message, extras.threadChannelId != null),
  );
}

bool _groupContinues(
  MessageTranscript transcript,
  Message message,
  Message? next,
  MessageExtras extras,
  String? nextWebhookUsername,
) {
  if (next == null) return false;
  final grouped = isGrouped(
    next,
    message,
    webhookUsername: nextWebhookUsername,
    previousWebhookUsername: extras.webhookUsername,
  );
  return grouped &&
      !isNewDay(next, message, historyKnown: transcript.historyKnown);
}

MessageRowCallbacks transcriptRowCallbacks(
  BuildContext context,
  MessageTranscript transcript,
  Message message,
) {
  final onEditFailed = transcript.onEditFailed;
  final onRank = transcript.onRank;
  final replyToId = message.replyToId;
  return MessageRowCallbacks(
    onRetry: () => transcript.onRetry(message),
    onDiscard: () => transcript.onDiscard(message),
    onEditFailed: onEditFailed == null ? null : () => onEditFailed(message),
    onPickReaction: (emoji) => transcript.onPickReaction(message, emoji),
    onReactionTap: (reaction) => transcript.onReactionTap(message, reaction),
    onVote: (option) => transcript.onVote(message, option),
    onRank: onRank == null ? null : (ranking) => onRank(message, ranking),
    onSubmitEdit: (content) => transcript.onSubmitEdit(message, content),
    onCancelEdit: transcript.onCancelEdit,
    onViewEditHistory: () =>
        showMessageEditHistorySheet(context, transcript.channelId, message.id),
    onReplyTap: replyToId == null
        ? null
        : () => transcript.onJumpToReply(replyToId),
  );
}
