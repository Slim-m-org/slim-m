// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The schema-24 `channels.default_notification` column, for a test that
/// downgrades below v24 while the table still exists.
library;

import 'package:slimm_data/src/database.dart';

Future<void> dropV24Columns(SlimmDatabase db) => db.customStatement(
      'ALTER TABLE channels DROP COLUMN default_notification',
    );
