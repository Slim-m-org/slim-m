// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The schema-22 temporary-room columns, for a test that downgrades below
/// v22 by dropping them from a fresh database.
library;

import 'package:slimm_data/src/database.dart';

const v22ChannelColumns = [
  'creates_rooms',
  'user_limit',
  'room_owner_id',
  'room_locked',
];

Future<void> dropV22Columns(SlimmDatabase db) async {
  for (final column in v22ChannelColumns) {
    await db.customStatement('ALTER TABLE channels DROP COLUMN $column');
  }
}
