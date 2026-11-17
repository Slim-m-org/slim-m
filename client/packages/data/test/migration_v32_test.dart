// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-32 migration, which adds `messages.editedByModerator`, and
/// that every server copy and sync edit restates the flag rather than keeping it.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

Future<void> _downgradeToV31(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE messages DROP COLUMN edited_by_moderator',
  );
  await db.customStatement('PRAGMA user_version = 31');
  await db.close();
}

api.Message _message({bool byModerator = false}) => api.Message(
      id: 'm1',
      channelId: 'c1',
      authorId: 'u1',
      authorDisplayName: 'U',
      seq: 1,
      content: 'words',
      createdAt: 1,
      editedAt: 2,
      editedByModerator: byModerator,
    );

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v32');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV31(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client gains the column', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final columns = await db.customSelect('PRAGMA table_info(messages)').get();

    expect(
      columns.map((r) => r.read<String>('name')),
      contains('edited_by_moderator'),
    );
  });

  test('the flag follows the latest server copy and sync edit', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'g', kind: 'text', createdAt: 1),
    ]);
    Future<bool> flag() async =>
        (await store.watchChannel('c1').first).single.editedByModerator;

    await store.applyMessage(_message(byModerator: true));
    expect(await flag(), isTrue);
    await store.applyMessage(_message());
    expect(await flag(), isFalse, reason: 'the author edited it back');
    await store.applyEdit('m1', 'moderated', 3, byModerator: true);
    expect(await flag(), isTrue);
    await store.applyEdit('m1', 'mine again', 4);
    expect(await flag(), isFalse);
  });
}
