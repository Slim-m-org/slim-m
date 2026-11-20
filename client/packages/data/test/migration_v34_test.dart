// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-34 migration, which records a held mention a catch-up edit
/// op left unsure, so a cold start still asks the server about it.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

Future<void> _v33WithMention(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 1),
  ]);
  await store.applyMessages([
    const api.Message(
      id: 'm9',
      channelId: 'c1',
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: 9,
      content: 'hi @me',
      createdAt: 1000,
      editedAt: null,
      mentionsMe: true,
    ),
  ]);
  await db.customStatement('ALTER TABLE messages DROP COLUMN mention_unsure');
  await db.customStatement('PRAGMA user_version = 33');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v34');
    file = File('${dir.path}/slimm.sqlite');
    await _v33WithMention(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client keeps its mention, and an op edit makes it ask',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);
    expect((await store.allCursors()).single.checkMention, isFalse);

    await store.applyEdit('m9', 'hi again @me', 2000);
    await db.close();

    final reopened = SlimmDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final again = MessageStore(reopened);
    final cursor = (await again.allCursors()).single;
    expect((cursor.checkMention, (await again.channelRow('c1'))!.mentionedSeq),
        (true, 9));

    await again.healMentionCursor('c1', 9);
    expect((await again.allCursors()).single.checkMention, isFalse);
  });
}
