// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bodies behind [MessageStore.drafts] and [MessageStore.saveDraft], a
/// sibling library that takes the store.
///
/// Drafts are the one table that is not a cache of server state: they cannot be
/// refetched, which is why `MessageStore.clear()` has to remember them.
library;

import 'database.dart';
import 'message_store.dart';

/// Every channel's unsent composer text, as a map.
///
/// Read whole rather than per channel: there is one row per channel a member
/// has unfinished words in, which is a handful, and the composer needs an
/// answer synchronously when a channel opens rather than a future to await.
Future<Map<String, String>> drafts(MessageStore store) async {
  final rows = await store.db.select(store.db.channelDrafts).get();
  return {for (final row in rows) row.channelId: row.body};
}

/// Saves [text] as [channelId]'s draft, or deletes the row when it is empty.
///
/// Empty deletes rather than storing a blank, so "no draft" has one
/// representation and a member who opens and leaves every channel empty does
/// not accumulate a row per channel forever.
Future<void> saveDraft(
  MessageStore store,
  String channelId,
  String text,
  int now,
) async {
  if (text.isEmpty) {
    await clearDraft(store, channelId);
    return;
  }
  await store.db.into(store.db.channelDrafts).insertOnConflictUpdate(
        ChannelDraftsCompanion.insert(
          channelId: channelId,
          body: text,
          updatedAt: now,
        ),
      );
}

Future<void> clearDraft(MessageStore store, String channelId) async {
  await (store.db.delete<ChannelDrafts, ChannelDraftRow>(store.db.channelDrafts)
        ..where((d) => d.channelId.equals(channelId)))
      .go();
}
