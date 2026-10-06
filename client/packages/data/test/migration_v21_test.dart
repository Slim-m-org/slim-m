// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-21 migration, which adds the `pending_attachments` table.
///
/// Builds a version-20 database by dropping the new table from a fresh one, so
/// the seed cannot drift from the real schema.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/src/database.dart';

Future<void> _downgradeToV20(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.customStatement('DROP TABLE pending_attachments');
  await db.customStatement('PRAGMA user_version = 20');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v21');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV20(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client gains an empty pending_attachments table',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    final rows = await db.select(db.pendingAttachments).get();

    expect(
      tables.map((r) => r.read<String>('name')),
      contains('pending_attachments'),
    );
    expect(rows, isEmpty);
  });

  test('the messages already held are untouched', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(await db.select(db.messages).get(), isEmpty);
    expect(db.schemaVersion, 21);
  });
}
