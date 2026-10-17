// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The schema-23 `pending_attachments.mention_reply` column, for a test that
/// downgrades below v23 while the table still exists.
library;

import 'package:slimm_data/src/database.dart';

Future<void> dropV23Columns(SlimmDatabase db) => db.customStatement(
      'ALTER TABLE pending_attachments DROP COLUMN mention_reply',
    );
