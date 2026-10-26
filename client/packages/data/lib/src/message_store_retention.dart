// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_store.dart';

/// [MessageStore.pruneToRetentionCeiling]'s body, split out for the same
/// reason `message_store_batch.dart` is: a top-level function in this
/// library rather than an extension, so the public method on [MessageStore]
/// stays the real thing every caller reaches through the type.
///
/// [ceiling] is the caller's own retention policy (`channelWindowCeiling` in
/// the app package's `providers/retention_policy.dart`), passed in rather
/// than owned here: `data` sits below `app` in the workspace's layering and
/// cannot import it. Deleting past it is always safe no matter which
/// channels a caller currently has open: a channel's live-watched window can
/// never be asked to grow past that same ceiling (`cappedChannelWindow`), so
/// the newest [ceiling] rows of every channel already cover whatever any
/// window, open now or reopened later, could ever show.
///
/// Pending and failed sends (`seq` 0) are never touched by the threshold
/// below - they are not delivered history to cap, and a queued or failed
/// send is exactly the row a retry or a manual resend still needs.
Future<void> _pruneToRetentionCeiling(MessageStore store, int ceiling) async {
  final db = store.db;
  final channelIds = await _distinctMessageChannelIds(db);
  await db.transaction(() async {
    for (final channelId in channelIds) {
      final thresholdRow = await (db.select(db.messages)
            ..where(
              (m) => m.channelId.equals(channelId) & m.seq.isBiggerThanValue(0),
            )
            ..orderBy([
              (m) => OrderingTerm(expression: m.seq, mode: OrderingMode.desc),
            ])
            ..limit(1, offset: ceiling - 1))
          .getSingleOrNull();
      // Fewer than `ceiling` delivered rows for this channel: nothing to prune.
      if (thresholdRow == null) continue;
      final threshold = thresholdRow.seq;
      await (db.delete(db.messages)
            ..where(
              (m) =>
                  m.channelId.equals(channelId) &
                  m.seq.isBiggerThanValue(0) &
                  m.seq.isSmallerThanValue(threshold),
            ))
          .go();
    }
  });
  await _reclaimFreedPages(store.db);
}

/// SQLite parks the pages a delete frees on its own free list rather than
/// handing them back to the OS, so a pruned cache never shrinks on disk until
/// something runs VACUUM. VACUUM rewrites the whole database, so it is worth
/// doing only once the free list has grown enough to reclaim - not after
/// every sweep, most of which prune little or nothing.
///
/// The floor is 512 pages, roughly 2 MiB at SQLite's 4 KiB default page size:
/// below that there is nothing worth a full rewrite for.
const _vacuumFreePageFloor = 512;

Future<void> _reclaimFreedPages(SlimmDatabase db) async {
  final row = await db.customSelect('PRAGMA freelist_count').getSingle();
  final freePages = row.data.values.first as int? ?? 0;
  if (freePages < _vacuumFreePageFloor) return;
  // Must run outside a transaction; the prune's own transaction has committed.
  await db.customStatement('VACUUM');
}

/// [MessageStore.reachableMessageIds]'s body: every message id already held
/// locally for [channelIds].
///
/// Meaningful as a reachability answer only once [_pruneToRetentionCeiling]
/// has already run this session: after that, no channel holds more than the
/// ceiling, so "every row this channel still has" and "every row a
/// still-open window could ever show" are the same set, which is what lets
/// `retention_sweep.dart` use this directly to decide what
/// `MessageExtrasController` may keep.
Future<Set<String>> _reachableMessageIds(
  MessageStore store,
  Iterable<String> channelIds,
) async {
  final ids = channelIds.toSet();
  if (ids.isEmpty) return const {};
  final messages = store.db.messages;
  final query = store.db.selectOnly(messages)
    ..addColumns([messages.id])
    ..where(messages.channelId.isIn(ids));
  final rows = await query.get();
  return rows.map((r) => r.read(messages.id)!).toSet();
}

/// The distinct set of channel ids [Messages] currently holds any row for -
/// including a thread's, which is a channel row like any other here.
Future<Set<String>> _distinctMessageChannelIds(SlimmDatabase db) async {
  final query = db.selectOnly(db.messages, distinct: true)
    ..addColumns([db.messages.channelId]);
  final rows = await query.get();
  return rows.map((r) => r.read(db.messages.channelId)!).toSet();
}
