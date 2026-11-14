// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-29 migration, which adds `channels.liveSeq` and fills it
/// from the rows held, so a channel left unread by a deleted message clears on upgrade.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

Future<void> _v28WithRows(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.customStatement('ALTER TABLE channels DROP COLUMN live_seq');
  await db.customStatement('PRAGMA user_version = 28');
  for (final (id, cursor) in [('deleted-tail', 5), ('nothing-held', 7)]) {
    await db.customStatement(
      'INSERT INTO channels (id, name, kind, created_at, cursor, last_read_seq) '
      "VALUES ('$id', '$id', 'text', 1, $cursor, 3)",
    );
  }
  for (final seq in [1, 2, 3]) {
    await db.customStatement(
      'INSERT INTO messages (id, channel_id, seq, content, created_at) '
      "VALUES ('m$seq', 'deleted-tail', $seq, 'hello', 1)",
    );
  }
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v29');
    file = File('${dir.path}/slimm.sqlite');
    await _v28WithRows(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('the newest row held becomes the standing seq', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final rows = {
      for (final row in await MessageStore(db).allChannels()) row.id: row,
    };

    expect(rows['deleted-tail']!.standingSeq, 3);
    expect(
        rows['deleted-tail']!.standingSeq > rows['deleted-tail']!.lastReadSeq,
        isFalse);
    expect(rows['nothing-held']!.standingSeq, 7,
        reason: 'with no rows to go by, the cursor stands in');
  });
}
