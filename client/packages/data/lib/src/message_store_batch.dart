// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:slimm_api/api.dart' as api;
import 'database.dart';
import 'message_store.dart';
import 'message_store_rows.dart' as rows_impl;

/// The batch body behind [MessageStore.applyMessages], a sibling library that
/// takes the store so `message_store.dart` stays under its file budget.
Future<void> applyMessagesBatched(
  MessageStore store,
  Iterable<api.Message> messages,
  CursorAdvance advance,
) async {
  final db = store.db;
  final incoming = messages.toList(growable: false);
  if (incoming.isEmpty) return;
  await db.transaction(() async {
    final ids = {for (final m in incoming) m.id}.toList(growable: false);
    final stored = <String, MessageRow>{
      for (final row
          in await (db.select(db.messages)..where((m) => m.id.isIn(ids))).get())
        row.id: row,
    };
    final winners = batchWinners(incoming, stored);
    if (winners.isEmpty) return;

    await db.batch((batch) {
      batch.insertAllOnConflictUpdate(db.messages, [
        for (final message in winners.values) rows_impl.rowFor(message),
      ]);
    });

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

// Same stale-and-pending rules as applyMessage, resolved once against the pre-read rows and across duplicate ids in the batch (highest seq wins; an equal seq lets the later copy overwrite, as a re-apply does).
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
