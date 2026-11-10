// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The transcript read: unsent rows first, then the newest delivered ones.
library;

import 'package:drift/drift.dart';

import 'database.dart';

/// The newest [limit] rows of [channelId], unsent (`seq = 0`) ahead of delivered.
///
/// Two index-served branches merged, because an `ORDER BY seq = 0` term cannot
/// use `messages_channel_seq` and would sort the whole channel on every write.
Selectable<MessageRow> channelTranscript(
  SlimmDatabase db,
  String channelId,
  int limit,
) {
  return db.customSelect(
    'SELECT * FROM ('
    'SELECT * FROM (SELECT *, 0 AS grp FROM messages '
    'WHERE channel_id = ? AND seq = 0 ORDER BY created_at DESC LIMIT ?) '
    'UNION ALL '
    'SELECT * FROM (SELECT *, 1 AS grp FROM messages '
    'WHERE channel_id = ? AND seq > 0 '
    'ORDER BY seq DESC, created_at DESC LIMIT ?)) '
    'ORDER BY grp, seq DESC, created_at DESC LIMIT ?',
    variables: [
      Variable.withString(channelId),
      Variable.withInt(limit),
      Variable.withString(channelId),
      Variable.withInt(limit),
      Variable.withInt(limit),
    ],
    readsFrom: {db.messages},
  ).map((row) => db.messages.map(row.data));
}

/// How many rows [channelTranscript] must be asked for to include
/// [messageId], or null when this channel holds no such message.
///
/// Counts unsent rows plus every delivered row at or above the message's own
/// `seq`, which is exactly what the newest-first window has to reach.
Future<int?> transcriptDepth(
  SlimmDatabase db,
  String channelId,
  String messageId,
) async {
  final target = await (db.select(db.messages)
        ..where((m) => m.channelId.equals(channelId) & m.id.equals(messageId)))
      .getSingleOrNull();
  if (target == null) return null;
  final row = await db.customSelect(
    'SELECT COUNT(*) AS depth FROM messages '
    'WHERE channel_id = ? AND (seq = 0 OR (? > 0 AND seq >= ?))',
    variables: [
      Variable.withString(channelId),
      Variable.withInt(target.seq),
      Variable.withInt(target.seq),
    ],
    readsFrom: {db.messages},
  ).getSingle();
  return row.read<int>('depth');
}

/// The `seq` of the oldest delivered row among [channelId]'s newest [rows], or
/// null when it holds none: how far back a window of that size reaches.
Future<int?> transcriptOldestSeq(
  SlimmDatabase db,
  String channelId,
  int rows,
) async {
  final row = await db.customSelect(
    'SELECT MIN(seq) AS oldest FROM ('
    'SELECT seq FROM messages WHERE channel_id = ? AND seq > 0 '
    'ORDER BY seq DESC LIMIT ?)',
    variables: [Variable.withString(channelId), Variable.withInt(rows)],
    readsFrom: {db.messages},
  ).getSingle();
  return row.readNullable<int>('oldest');
}
