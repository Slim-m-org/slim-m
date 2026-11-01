// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-28 migration, which adds `channels.dmMemberIds` so a group
/// DM keeps its roster through a cold start without a REST read.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

Future<void> _downgradeToV27(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.customStatement('ALTER TABLE channels DROP COLUMN dm_member_ids');
  await db.customStatement('PRAGMA user_version = 27');
  await db.close();
}

api.Channel _channel(String id, {List<String> members = const []}) =>
    api.Channel(
      id: id,
      name: 'A, B and C',
      kind: 'dm',
      createdAt: 1,
      dmParticipantId: members.isEmpty ? 'u2' : members.first,
      dmMemberIds: members,
    );

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v28');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV27(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client gains the column', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final columns = await db.customSelect('PRAGMA table_info(channels)').get();

    expect(
      columns.map((r) => r.read<String>('name')),
      contains('dm_member_ids'),
    );
  });

  test('a group roster survives a reopen and a pair has none', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    final store = MessageStore(db);
    await store.upsertChannels([
      _channel('group', members: ['u1', 'u2', 'u3']),
      _channel('pair'),
    ]);
    await db.close();

    final reopened = SlimmDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final rows = {
      for (final row in await MessageStore(reopened).allChannels()) row.id: row,
    };
    expect(rows['group']!.isGroupDm, isTrue);
    expect(rows['group']!.groupMemberIds, ['u1', 'u2', 'u3']);
    expect(rows['pair']!.isGroupDm, isFalse);
    expect(rows['pair']!.groupMemberIds, isEmpty);
  });

  test('a later refresh replaces the roster, and an emptied one clears it',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      _channel('group', members: ['u1', 'u2', 'u3']),
    ]);
    await store.upsertChannels([
      _channel('group', members: ['u1', 'u2']),
    ]);
    expect((await store.channelRow('group'))!.groupMemberIds, ['u1', 'u2']);

    await store.upsertChannels([_channel('group')]);
    expect((await store.channelRow('group'))!.isGroupDm, isFalse);
  });
}
