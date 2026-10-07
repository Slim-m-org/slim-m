// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_store.dart';

/// The bodies behind [MessageStore.drafts] and [MessageStore.saveDraft], split
/// out of `message_store.dart` once the drafts table pushed that file past its
/// line budget - the same `part of` shape
/// `message_store_channels.dart` and `message_store_batch.dart` already use.
///
/// Worth keeping together for a reason beyond the budget: this is the only table
/// in the local store that is not a cache of server state. Everything else here
/// can be refetched and these words cannot, which is why they are written at all
/// and why `MessageStore.clear()` has to remember them.

/// Every channel's unsent composer text, as a map.
///
/// Read whole rather than per channel: there is one row per channel a member
/// has unfinished words in, which is a handful, and the composer needs an
/// answer synchronously when a channel opens rather than a future to await.
Future<Map<String, String>> _drafts(MessageStore store) async {
  final rows = await store.db.select(store.db.channelDrafts).get();
  return {for (final row in rows) row.channelId: row.body};
}

/// Saves [text] as [channelId]'s draft, or deletes the row when it is empty.
///
/// Empty deletes rather than storing a blank, so "no draft" has one
/// representation and a member who opens and leaves every channel empty does
/// not accumulate a row per channel forever.
Future<void> _saveDraft(
  MessageStore store,
  String channelId,
  String text,
  int now,
) async {
  if (text.isEmpty) {
    await _clearDraft(store, channelId);
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

Future<void> _clearDraft(MessageStore store, String channelId) async {
  await (store.db.delete<ChannelDrafts, ChannelDraftRow>(store.db.channelDrafts)
        ..where((d) => d.channelId.equals(channelId)))
      .go();
}
