// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-22 migration: the temporary-room columns (decision 0065)
/// arrive on an upgrading client, null on every row it already holds.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/src/database.dart';

import 'support/v22_columns.dart';
import 'support/v23_columns.dart';

Future<void> _downgradeToV21(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.into(db.channels).insert(
        ChannelsCompanion.insert(
          id: 'chan-1',
          name: 'lounge',
          kind: 'voice',
          createdAt: 900,
        ),
      );
  await dropV22Columns(db);
  await dropV23Columns(db);
  await db.customStatement('PRAGMA user_version = 21');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v22');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV21(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client gains every temporary-room column', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final columns = await db.customSelect('PRAGMA table_info(channels)').get();
    expect(
      columns.map((r) => r.read<String>('name')),
      containsAll(v22ChannelColumns),
    );
  });

  test('an existing channel keeps its row with the new columns null', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final channel = await db.select(db.channels).getSingle();
    expect(channel.name, 'lounge');
    expect(channel.createsRooms, isNull);
    expect(channel.roomOwnerId, isNull);
  });
}
