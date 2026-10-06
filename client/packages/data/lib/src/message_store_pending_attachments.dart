// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_store.dart';

/// Remembers the ids a queued send carries, or forgets them when it has none.
Future<void> _savePendingAttachments(
  MessageStore store,
  String messageId,
  List<String> ids,
) async {
  if (ids.isEmpty) {
    await _forgetPendingAttachments(store, messageId);
    return;
  }
  await store.db.into(store.db.pendingAttachments).insertOnConflictUpdate(
        PendingAttachmentsCompanion.insert(
          messageId: messageId,
          attachmentIds: ids,
        ),
      );
}

Future<List<String>> _pendingAttachmentIds(
  MessageStore store,
  String messageId,
) async {
  final row = await (store.db.select(store.db.pendingAttachments)
        ..where((p) => p.messageId.equals(messageId)))
      .getSingleOrNull();
  if (row == null) return const [];
  return row.attachmentIds;
}

Future<void> _forgetPendingAttachments(
  MessageStore store,
  String messageId,
) async {
  await (store.db.delete(store.db.pendingAttachments)
        ..where((p) => p.messageId.equals(messageId)))
      .go();
}
