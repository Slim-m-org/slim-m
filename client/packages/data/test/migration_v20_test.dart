// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-20 migration, which adds `messages.forwardedRemoved` for a
/// forward whose original was deleted.
///
/// Builds a version-19 database by dropping the new column from a fresh one,
/// so the seed cannot drift from the real schema.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/src/database.dart';

import 'support/v22_columns.dart';
import 'support/v24_columns.dart';

Future<void> _downgradeToV19(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE messages DROP COLUMN forwarded_removed',
  );
  await dropV22Columns(db);
  await dropV24Columns(db);
  await db.customStatement('PRAGMA user_version = 19');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v20');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV19(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client gains a real messages.forwarded_removed column',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final columns = await db.customSelect('PRAGMA table_info(messages)').get();

    expect(
      columns.map((r) => r.read<String>('name')),
      contains('forwarded_removed'),
    );
  });
}
