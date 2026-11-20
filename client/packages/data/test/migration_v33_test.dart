// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-33 migration, which records per category whether this
/// account may manage it and file under it, so a cold start offers no rename,
/// delete or drag on a heading before the first listing arrives.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

Future<void> _v32WithRows(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db
      .customStatement('ALTER TABLE channel_categories DROP COLUMN manageable');
  await db
      .customStatement('ALTER TABLE channel_categories DROP COLUMN fileable');
  await db.customStatement('PRAGMA user_version = 32');
  await db.customStatement(
    "INSERT INTO channel_categories (id, name) VALUES ('gamers', 'Gamers')",
  );
  await db.close();
}

Future<ChannelCategoryRow> _row(MessageStore store, String id) async =>
    (await store.allCategories()).firstWhere((c) => c.id == id);

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v33');
    file = File('${dir.path}/slimm.sqlite');
    await _v32WithRows(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client keeps its categories, manageable until told',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final gamers = await _row(MessageStore(db), 'gamers');

    expect((gamers.manageable, gamers.canManage, gamers.canFile),
        (null, true, true));
  });

  test('a listing after the upgrade records a heading, and keeps it', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);

    await store.replaceCategories(const [
      api.ChannelCategory(
        id: 'gamers',
        name: 'Gamers',
        position: 0,
        createdAt: 0,
        manageable: false,
        fileable: false,
      ),
    ]);
    await db.close();

    final reopened = SlimmDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final gamers = await _row(MessageStore(reopened), 'gamers');
    expect((gamers.manageable, gamers.fileable), (false, false));
  });
}
