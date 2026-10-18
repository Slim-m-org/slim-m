// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-19 migration, which is what an upgrading client needs to
/// hold a channel's own `joinMuted` flag.
///
/// Builds a version-18 database by taking a fresh one and dropping the new
/// column, so the seed cannot drift from the real schema the way a
/// hand-written CREATE TABLE would.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/src/database.dart';

import 'support/v22_columns.dart';
import 'support/v24_columns.dart';

Future<void> _downgradeToV18(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.into(db.channels).insert(
        ChannelsCompanion.insert(
          id: 'chan-1',
          name: 'general',
          kind: 'voice',
          createdAt: 900,
        ),
      );
  await db.customStatement('ALTER TABLE channels DROP COLUMN join_muted');
  await db.customStatement(
    'ALTER TABLE messages DROP COLUMN forwarded_removed',
  );
  await dropV22Columns(db);
  await dropV24Columns(db);
  await db.customStatement('PRAGMA user_version = 18');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v19');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV18(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client gains a real channels.join_muted column', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final columns = await db.customSelect('PRAGMA table_info(channels)').get();

    expect(
      columns.map((r) => r.read<String>('name')),
      contains('join_muted'),
    );
  });

  test('an existing channel keeps its row and reads join muted as off',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final channel = await db.select(db.channels).getSingle();

    expect(channel.name, 'general');
    expect(channel.joinMuted, false);
  });
}
