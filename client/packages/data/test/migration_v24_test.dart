// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-24 migration: `channels.default_notification` arrives on
/// an upgrading client as 'everything' on every row it already holds.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/src/database.dart';

import 'support/v24_columns.dart';

Future<void> _downgradeToV23(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.into(db.channels).insert(
        ChannelsCompanion.insert(
          id: 'chan-1',
          name: 'general',
          kind: 'text',
          createdAt: 900,
        ),
      );
  await dropV24Columns(db);
  await db.customStatement('PRAGMA user_version = 23');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v24');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV23(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an existing channel has no default stored', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = await db.select(db.channels).getSingle();
    expect(row.defaultNotification, isNull);
    expect(db.schemaVersion, greaterThanOrEqualTo(24));
  });
}
