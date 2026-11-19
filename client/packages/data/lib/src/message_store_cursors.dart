// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel-cursor reads and the op-cursor write behind [MessageStore], a
/// sibling library that takes the store so `message_store.dart` stays under its
/// file budget.
library;

import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:slimm_api/api.dart' as api;
import 'database.dart';
import 'message_store.dart';

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

/// When a write of message rows may move a channel's sync cursor.
enum CursorAdvance {
  /// Only when the rows join the cursor with no seq between, or the channel
  /// holds nothing yet.
  ///
  /// Moving it over a gap would make the next catch-up ask after the rows
  /// that were never fetched, which then never come.
  whenContiguous,

  /// Whatever the rows: they are the sync stream's own answer to the cursor,
  /// where a seq the server no longer lists is not a gap. A row the cursor
  /// has since passed is only written when it is already held.
  always,
}

/// Moves a channel's cursor forward to the newest of [seqs], as [advance] allows.
///
/// Never backwards: the cursor is the high-water mark of what has been applied.
Future<void> advanceCursorHelper(
  MessageStore store,
  String channelId,
  Iterable<int> seqs,
  CursorAdvance advance,
) async {
  final db = store.db;
  final row = await (db.select(db.channels)
        ..where((c) => c.id.equals(channelId)))
      .getSingleOrNull();
  final newest = seqs.reduce(math.max);
  if (row == null) return;
  // A row stands once it is stored, whether or not the cursor may move over it.
  if ((row.liveSeq ?? row.cursor) < newest) {
    await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
        .write(ChannelsCompanion(liveSeq: Value(newest)));
  }
  if (row.cursor >= newest) return;
  final cursor = row.cursor;
  if (advance == CursorAdvance.whenContiguous && cursor > 0) {
    final nextHeld = seqs.where((seq) => seq > cursor).reduce(math.min);
    if (nextHeld > cursor + 1) return;
  }
  await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
      .write(ChannelsCompanion(cursor: Value(newest)));
}

/// Raises a channel's cursor to [seq] without a row at it; see [MessageStore.coverCursor].
///
/// The standing seq is pinned first where it was still read off the cursor,
/// so covering deleted messages does not light the channel as unread.
Future<void> coverCursorHelper(
    MessageStore store, String channelId, int seq) async {
  final db = store.db;
  await db.transaction(() async {
    final row = await channelRow(store, channelId);
    if (row == null || row.cursor >= seq) return;
    await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
        .write(ChannelsCompanion(
      cursor: Value(seq),
      liveSeq: Value(row.liveSeq ?? row.cursor),
    ));
  });
}

/// Drops one message row, walking the channel's standing seq and mention cursor back to the newest row left of each.
/// With [serverDeleted] the message is remembered as deleted, so a late copy of it is not stored again.
Future<void> discardRowHelper(
  MessageStore store,
  String id, {
  required bool serverDeleted,
}) async {
  final db = store.db;
  await db.transaction(() async {
    final gone = await (db.select(db.messages)..where((m) => m.id.equals(id)))
        .getSingleOrNull();
    await (db.delete(db.messages)..where((m) => m.id.equals(id))).go();
    // Also a row still pending: its send can answer after the delete arrives.
    if (serverDeleted) store.recentOps.removed(id);
    if (gone == null || gone.seq <= 0) return;
    final row = await channelRow(store, gone.channelId);
    if (row == null) return;
    final standing = row.liveSeq ?? row.cursor;
    final newest = standing > gone.seq
        ? standing
        : await _newestHeldSeq(db, gone.channelId);
    await (db.update(db.channels)..where((c) => c.id.equals(gone.channelId)))
        .write(ChannelsCompanion(
      liveSeq: Value(newest),
      mentionedSeq: row.mentionedSeq == gone.seq
          ? Value(await _newestHeldSeq(db, gone.channelId, mentionsOnly: true))
          : const Value.absent(),
    ));
  });
}

Future<int> _newestHeldSeq(
  SlimmDatabase db,
  String channelId, {
  bool mentionsOnly = false,
}) async {
  final mentions = mentionsOnly ? ' AND mentions_me = 1' : '';
  final got = await db.customSelect(
    'SELECT MAX(seq) AS newest FROM messages '
    'WHERE channel_id = ? AND seq > 0$mentions',
    variables: [Variable.withString(channelId)],
    readsFrom: {db.messages},
  ).getSingle();
  return got.read<int?>('newest') ?? 0;
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

/// Lowers the mention cursor to the server's [seq] when no held message at it
/// still mentions this account, since then nothing local can walk it back.
Future<void> healMentionCursorHelper(
    MessageStore store, String channelId, int seq) async {
  final db = store.db;
  await db.transaction(() async {
    final row = await channelRow(store, channelId);
    if (row == null || row.mentionedSeq <= seq) return;
    final held = await (db.select(db.messages)
          ..where((m) =>
              m.channelId.equals(channelId) &
              m.seq.equals(row.mentionedSeq) &
              m.mentionsMe.equals(true))
          ..limit(1))
        .getSingleOrNull();
    if (held != null) return;
    await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
        .write(ChannelsCompanion(mentionedSeq: Value(seq)));
  });
}

Future<List<api.ScopeCursor>> allCursors(MessageStore store) async {
  final rows = await store.db.select(store.db.channels).get();
  final unheld = await _unheldMentionChannels(store.db);
  return rows
      .map((c) => api.ScopeCursor(
            channelId: c.id,
            afterSeq: c.cursor,
            afterOpSeq: c.opCursor,
            checkMention: unheld.contains(c.id),
          ))
      .toList(growable: false);
}

/// Channels lit by a mention cursor naming no held mention: a reset's marker, or one edited away.
Future<Set<String>> _unheldMentionChannels(SlimmDatabase db) async {
  final rows = await db.customSelect(
    'SELECT c.id AS id FROM channels c WHERE c.mentioned_seq > c.last_read_seq '
    'AND NOT EXISTS (SELECT 1 FROM messages m '
    'WHERE m.channel_id = c.id AND m.seq = c.mentioned_seq '
    'AND m.mentions_me = 1)',
    readsFrom: {db.channels, db.messages},
  ).get();
  return {for (final row in rows) row.read<String>('id')};
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
