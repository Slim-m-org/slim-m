// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:drift/drift.dart';
import 'database.dart';
import 'message_store.dart';

/// Marks a stored id as a spoiler. Attachment ids are hex, so the mark can
/// never collide with one, and rows written before spoilers read as plain.
const spoilerMark = '!';

/// Remembers the ids a queued send carries, or forgets them when it has none.
Future<void> savePendingAttachments(
  MessageStore store,
  String messageId,
  List<String> ids,
  List<String> spoilerIds, {
  bool mentionReply = true,
}) async {
  ids = [
    for (final id in ids) spoilerIds.contains(id) ? '$spoilerMark$id' : id,
  ];
  if (ids.isEmpty && mentionReply) {
    await forgetPendingAttachments(store, messageId);
    return;
  }
  await store.db.into(store.db.pendingAttachments).insertOnConflictUpdate(
        PendingAttachmentsCompanion.insert(
          messageId: messageId,
          attachmentIds: ids,
          mentionReply: Value(mentionReply ? null : false),
        ),
      );
}

Future<List<String>> pendingAttachmentIds(
  MessageStore store,
  String messageId, {
  bool spoilersOnly = false,
}) async {
  final row = await (store.db.select(store.db.pendingAttachments)
        ..where((p) => p.messageId.equals(messageId)))
      .getSingleOrNull();
  if (row == null) return const [];
  return [
    for (final id in row.attachmentIds)
      if (!spoilersOnly || id.startsWith(spoilerMark))
        id.startsWith(spoilerMark) ? id.substring(1) : id,
  ];
}

Future<bool> pendingMentionReply(MessageStore store, String messageId) async {
  final row = await (store.db.select(store.db.pendingAttachments)
        ..where((p) => p.messageId.equals(messageId)))
      .getSingleOrNull();
  return row?.mentionReply ?? true;
}

Future<void> forgetPendingAttachments(
  MessageStore store,
  String messageId,
) async {
  await (store.db.delete(store.db.pendingAttachments)
        ..where((p) => p.messageId.equals(messageId)))
      .go();
}
