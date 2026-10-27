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
