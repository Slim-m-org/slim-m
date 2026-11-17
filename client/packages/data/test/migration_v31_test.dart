// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-31 migration, which adds `channel_categories.parentId`
/// so a sub-category keeps its place through a cold start (decision 0120).
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

Future<void> _v30WithRows(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db
      .customStatement('ALTER TABLE channel_categories DROP COLUMN parent_id');
  await db.customStatement('PRAGMA user_version = 30');
  await db.customStatement(
    'INSERT INTO channel_categories (id, name, position) '
    "VALUES ('gamers', 'gamers', 0), ('cs2', 'cs2', 1)",
  );
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v31');
    file = File('${dir.path}/slimm.sqlite');
    await _v30WithRows(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client keeps its categories, all top-level', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final rows = await MessageStore(db).allCategories();

    expect(rows.map((r) => r.id), ['gamers', 'cs2']);
    expect(rows.map((r) => r.parentId), [null, null]);
  });

  test('a refresh after the upgrade files a sub-category under its parent',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    final store = MessageStore(db);
    await store.replaceCategories(const [
      api.ChannelCategory(
          id: 'gamers', name: 'gamers', position: 0, createdAt: 1),
      api.ChannelCategory(
        id: 'cs2',
        name: 'cs2',
        position: 0,
        createdAt: 1,
        parentId: 'gamers',
        serverNests: true,
      ),
    ]);
    await db.close();

    final reopened = SlimmDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final rows = {
      for (final row in await MessageStore(reopened).allCategories())
        row.id: row,
    };
    expect(rows['cs2']!.parentId, 'gamers');
    expect(rows['gamers']!.parentId, isNull);
  });
}
