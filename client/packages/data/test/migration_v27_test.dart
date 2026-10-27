// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-27 migration, which adds `messages.linkPreviewsRemoved` so
/// a removal survives a cold start without a REST read.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

Future<void> _downgradeToV26(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE messages DROP COLUMN link_previews_removed',
  );
  await db.customStatement('PRAGMA user_version = 26');
  await db.close();
}

api.Message _message({bool removed = false, int seq = 1}) => api.Message(
      id: 'm1',
      channelId: 'c1',
      authorId: 'u1',
      authorDisplayName: 'U',
      seq: seq,
      content: 'see https://example.com',
      createdAt: 1,
      editedAt: null,
      linkPreviewsRemoved: removed,
    );

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v27');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV26(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client gains the column and it defaults to false',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final columns = await db.customSelect('PRAGMA table_info(messages)').get();

    expect(
      columns.map((r) => r.read<String>('name')),
      contains('link_previews_removed'),
    );
  });

  test('a removal is stored, read back, and not undone by a later write',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'g', kind: 'text', createdAt: 1),
    ]);
    await store.applyMessage(_message());
    expect((await store.watchChannel('c1').first).single.linkPreviewsRemoved,
        isFalse);

    await store.markLinkPreviewsRemoved('m1');
    await store.applyMessage(_message(seq: 2));

    expect((await store.watchChannel('c1').first).single.linkPreviewsRemoved,
        isTrue,
        reason: 'an edit frame says false and must not bring the cards back');
  });

  test('a REST message that carries the flag stores it', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'g', kind: 'text', createdAt: 1),
    ]);
    await store.applyMessages([_message(removed: true)]);

    expect((await store.watchChannel('c1').first).single.linkPreviewsRemoved,
        isTrue);
  });
}
