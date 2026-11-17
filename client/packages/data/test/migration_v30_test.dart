// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-30 migration, which adds `messages.mentionsMe` and marks
/// the row each channel's mention cursor already points at.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

Future<void> _v29WithRows(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.customStatement('ALTER TABLE messages DROP COLUMN mentions_me');
  await db.customStatement('PRAGMA user_version = 29');
  await db.customStatement(
    'INSERT INTO channels (id, name, kind, created_at, cursor, live_seq, '
    'last_read_seq, mentioned_seq) '
    "VALUES ('c1', 'general', 'text', 1, 3, 3, 1, 2)",
  );
  for (final seq in [1, 2, 3]) {
    await db.customStatement(
      'INSERT INTO messages (id, channel_id, seq, content, created_at) '
      "VALUES ('m$seq', 'c1', $seq, 'hello', 1)",
    );
  }
  await db.close();
}

api.Message _mention(int seq) => api.Message(
      id: 'm$seq',
      channelId: 'c1',
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: 'hello',
      createdAt: 1,
      editedAt: null,
      mentionsMe: true,
    );

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v30');
    file = File('${dir.path}/slimm.sqlite');
    await _v29WithRows(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('a mention held before the upgrade is still known after it', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.applyMessage(_mention(4));

    await store.discard('m4');

    final row = (await store.allChannels()).single;
    expect(row.mentionedSeq, 2, reason: 'm2 was the mention cursor at v29');
  });
}
