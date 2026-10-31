// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:drift/drift.dart';
import 'package:slimm_api/api.dart' as api;
import 'database.dart';
import 'message_store.dart';

/// The channel-cursor reads and the op-cursor write behind [MessageStore],
/// split out of `message_store.dart` to stay under the file budget. Private
/// top-level functions, like `message_store_batch.dart`, so the public methods
/// stay real methods on the type.
Future<Channel?> channelRow(MessageStore store, String channelId) =>
    (store.db.select(store.db.channels)..where((c) => c.id.equals(channelId)))
        .getSingleOrNull();

Future<int?> cursorFor(MessageStore store, String channelId) async =>
    (await channelRow(store, channelId))?.cursor;

Future<int?> opCursorFor(MessageStore store, String channelId) async =>
    (await channelRow(store, channelId))?.opCursor;

Future<void> setOpCursor(MessageStore store, String channelId, int? seq) async {
  final db = store.db;
  await db.transaction(() async {
    final row = await channelRow(store, channelId);
    if (row == null) return;
    if (seq != null && row.opCursor != null && row.opCursor! >= seq) return;
    await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
        .write(ChannelsCompanion(opCursor: Value(seq)));
  });
}

/// Moves a channel's cursor forward. Never backwards: the cursor is the
/// high-water mark of what has been applied.
Future<void> advanceCursorHelper(
    MessageStore store, String channelId, int seq) async {
  final db = store.db;
  final row = await (db.select(db.channels)
        ..where((c) => c.id.equals(channelId)))
      .getSingleOrNull();
  if (row == null || row.cursor >= seq) return;
  await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
      .write(ChannelsCompanion(cursor: Value(seq)));
}

/// [advanceCursorHelper]'s own shape for `mentionedSeq`, only ever called for a
/// message whose `mentionsMe` is true.
Future<void> advanceMentionCursorHelper(
    MessageStore store, String channelId, int seq) async {
  final db = store.db;
  final row = await (db.select(db.channels)
        ..where((c) => c.id.equals(channelId)))
      .getSingleOrNull();
  if (row == null || row.mentionedSeq >= seq) return;
  await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
      .write(ChannelsCompanion(mentionedSeq: Value(seq)));
}

Future<List<api.ScopeCursor>> allCursors(MessageStore store) async {
  final rows = await store.db.select(store.db.channels).get();
  return rows
      .map((c) => api.ScopeCursor(
            channelId: c.id,
            afterSeq: c.cursor,
            afterOpSeq: c.opCursor,
          ))
      .toList(growable: false);
}

Future<void> setReadMarker(
  MessageStore store,
  String channelId,
  int seq, {
  bool? manuallyUnread,
}) async {
  final db = store.db;
  await db.transaction(() async {
    final row = await (db.select(db.channels)
          ..where((c) => c.id.equals(channelId)))
        .getSingleOrNull();
    if (row == null) return;
    // The marker only moves forward; the flag is independent of it.
    final advancing = seq > row.lastReadSeq;
    if (!advancing && manuallyUnread == null) return;
    await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
        .write(ChannelsCompanion(
      lastReadSeq: advancing ? Value(seq) : const Value.absent(),
      manuallyUnread:
          manuallyUnread == null ? const Value.absent() : Value(manuallyUnread),
    ));
  });
}

/// One channel's server read marker, as [MessageStore.setReadMarkers] takes it.
typedef ReadMarker = ({String channelId, int seq, bool? manuallyUnread});

Future<void> setReadMarkers(
  MessageStore store,
  Iterable<ReadMarker> markers,
) =>
    store.db.transaction(() async {
      for (final marker in markers) {
        await store.setReadMarker(
          marker.channelId,
          marker.seq,
          manuallyUnread: marker.manuallyUnread,
        );
      }
    });
