// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:drift/drift.dart';
import 'package:slimm_api/api.dart' as api;
import 'database.dart';
import 'message_store.dart';
import 'message_store_recent_ops.dart';
import 'message_store_rows.dart' as rows_impl;

/// The body behind [MessageStore.applyMessage] and [MessageStore.applyMessages],
/// a sibling library that takes the store so `message_store.dart` stays under
/// its file budget.
///
/// Idempotent and order-safe: re-applying a message changes nothing, and an
/// older copy never replaces a newer one. Older means a lower `seq`, an edit
/// stamp behind the one stored or seen, or any copy of a message the server
/// has since deleted; see [RecentOps] for how a copy comes to be older.
Future<void> applyMessagesBatched(
  MessageStore store,
  Iterable<api.Message> messages,
  CursorAdvance advance,
) async {
  final db = store.db;
  final recent = store.recentOps;
  final incoming =
      messages.where((m) => !recent.isRemoved(m.id)).toList(growable: false);
  if (incoming.isEmpty) return;
  await db.transaction(() async {
    final ids = {for (final m in incoming) m.id}.toList(growable: false);
    final stored = <String, MessageRow>{
      for (final row
          in await (db.select(db.messages)..where((m) => m.id.isIn(ids))).get())
        row.id: row,
    };
    final winners = batchWinners(
      advance == CursorAdvance.always
          ? await _notAlreadyCovered(store, incoming, stored)
          : incoming,
      stored,
    );
    if (winners.isEmpty) return;
    final writes = [
      for (final message in winners.values)
        if (!_heldCopyIsNewer(stored[message.id], message)) message,
    ];

    await db.batch((batch) {
      batch.insertAllOnConflictUpdate(db.messages, [
        for (final message in writes) rows_impl.rowFor(message),
      ]);
    });
    for (final message in writes) {
      await _keepNewerState(store, stored[message.id], message);
    }

    final furthestMention = furthestSeqByChannel(
      winners.values.where((m) => m.mentionsMe),
    );
    for (final entry in seqsByChannel(winners.values).entries) {
      await store.advanceCursor(entry.key, entry.value, advance);
    }
    for (final entry in furthestMention.entries) {
      await store.advanceMentionCursor(entry.key, entry.value);
    }
  });
}

/// The sync stream's rows, less those at or below their channel's cursor that
/// are not held: the cursor passed them, so a missing one was deleted since.
///
/// The cursor can pass a page still in flight when live frames land first, or
/// when another tab on the same database applied it, and only that tab
/// remembers the delete.
Future<List<api.Message>> _notAlreadyCovered(
  MessageStore store,
  List<api.Message> incoming,
  Map<String, MessageRow> stored,
) async {
  final cursors = <String, int>{};
  for (final channelId in {for (final m in incoming) m.channelId}) {
    cursors[channelId] = await store.cursorFor(channelId) ?? 0;
  }
  return [
    for (final message in incoming)
      if (message.seq > cursors[message.channelId]! ||
          stored.containsKey(message.id))
        message,
  ];
}

/// Whether [prior] already holds an edit newer than [message] carries. A
/// pending row is the sender's own unsent text, which the server's copy replaces.
bool _heldCopyIsNewer(MessageRow? prior, api.Message message) =>
    prior != null &&
    !prior.pending &&
    (prior.editedAt ?? 0) > (message.editedAt ?? 0);

/// Puts back what the row just written must not lose: an edit seen while the
/// row was not held, and a forward snapshot already cleared.
Future<void> _keepNewerState(
  MessageStore store,
  MessageRow? prior,
  api.Message message,
) async {
  final edit = store.recentOps.newerThan(message.id, message.editedAt);
  if (edit != null) {
    await (store.db.update(store.db.messages)
          ..where((m) => m.id.equals(message.id)))
        .write(MessagesCompanion(
      content: Value(edit.content),
      editedAt: Value(edit.editedAt),
    ));
  }
  final forwarded = message.forwarded;
  if (prior != null &&
      prior.forwardedRemoved &&
      forwarded != null &&
      !forwarded.removed) {
    await rows_impl.removeForwardSnapshot(store.db, message.id);
  }
}

// The seq rule, resolved once against the pre-read rows and across duplicate ids in the batch (highest seq wins; an equal seq lets the later copy overwrite, as a re-apply does).
Map<String, api.Message> batchWinners(
  List<api.Message> incoming,
  Map<String, MessageRow> stored,
) {
  final winners = <String, api.Message>{};
  for (final message in incoming) {
    final chosen = winners[message.id];
    if (chosen != null && chosen.seq > message.seq) continue;
    final prior = stored[message.id];
    if (prior != null && !prior.pending && prior.seq > message.seq) continue;
    winners[message.id] = message;
  }
  return winners;
}

Map<String, List<int>> seqsByChannel(Iterable<api.Message> messages) {
  final seqs = <String, List<int>>{};
  for (final message in messages) {
    (seqs[message.channelId] ??= []).add(message.seq);
  }
  return seqs;
}

Map<String, int> furthestSeqByChannel(Iterable<api.Message> messages) {
  final furthest = <String, int>{};
  for (final message in messages) {
    final current = furthest[message.channelId];
    if (current == null || message.seq > current) {
      furthest[message.channelId] = message.seq;
    }
  }
  return furthest;
}
