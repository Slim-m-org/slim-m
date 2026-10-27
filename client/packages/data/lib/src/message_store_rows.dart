// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_store.dart';

/// The row a server-acknowledged message is stored as, shared by
/// [MessageStore.applyMessage] and the batch behind
/// [MessageStore.applyMessages] - which built the identical companion twice
/// until a forward gave them seven more columns to keep in step.
///
/// An absent forward is left untouched rather than written as null, which is
/// the same rule `MessageExtrasController.applyMessage` already follows for
/// reactions, attachments and polls, and for the same reason: a live frame
/// may simply omit what it has nothing to say about. Nothing un-forwards a
/// message - there is no such operation - so "not mentioned" can only mean
/// unchanged. Writing null here instead is what made an edit drop the
/// forwarded card off its own message until the next full resync.
MessagesCompanion _rowFor(api.Message message) {
  final row = MessagesCompanion.insert(
    id: message.id,
    channelId: message.channelId,
    authorId: Value(message.authorId),
    authorDisplayName: Value(message.authorDisplayName),
    seq: Value(message.seq),
    content: message.content,
    createdAt: message.createdAt,
    editedAt: Value(message.editedAt),
    pending: const Value(false),
    failed: const Value(false),
    replyToId: Value(message.replyToId),
  );
  final withPreviews = message.linkPreviewsRemoved
      ? row.copyWith(linkPreviewsRemoved: const Value(true))
      : row;
  final forwarded = message.forwarded;
  if (forwarded == null) return withPreviews;
  return withPreviews.copyWith(
    forwardedMessageId: Value(forwarded.messageId),
    forwardedChannelId: Value(forwarded.channelId),
    forwardedAuthorId: Value(forwarded.authorId),
    forwardedAuthorDisplayName: Value(forwarded.authorDisplayName),
    forwardedAuthorAvatarUpdatedAt: Value(forwarded.authorAvatarUpdatedAt),
    forwardedCreatedAt: Value(forwarded.createdAt),
    forwardedContent: Value(forwarded.content),
    forwardedRemoved: Value(forwarded.removed),
  );
}

/// [MessageStore.removeForwardSnapshot]'s body, split out to keep that file under its budget.
Future<void> _removeForwardSnapshot(SlimmDatabase db, String messageId) async {
  await (db.update(db.messages)..where((m) => m.id.equals(messageId))).write(
    const MessagesCompanion(
      forwardedRemoved: Value(true),
      forwardedContent: Value(''),
      forwardedAuthorId: Value(null),
      forwardedAuthorDisplayName: Value(null),
      forwardedAuthorAvatarUpdatedAt: Value(null),
    ),
  );
}
