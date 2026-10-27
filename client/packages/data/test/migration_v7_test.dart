// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-7 migration, which closes the pre-op-stream epoch.
///
/// Until the server had a message op stream, an edit or a delete made while a
/// client was offline reached it through nothing at all: edits do not advance
/// `seq`, deleted rows are filtered out of a delta, and a keyset sync only
/// ever asks for what is newer than the cursor. So a cached message could hold
/// text the server replaced months ago, permanently.
///
/// No cursor can reach behind the first op ever written, so the protocol
/// cannot heal that epoch. The cache is dropped once instead.
///
/// The seed here is version 6, not version 2, and that is the whole point:
/// a v6 client has already taken v3's wipe and would keep its stale rows
/// forever if this migration only fired for the versions v3 covered. The
/// sibling `migration_test.dart` covers the v2 path.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

/// Builds the schema exactly as version 6 left it: every column v6 had, an
/// advanced cursor, and a cached message the server may since have edited.
Future<void> _seedSchemaV6(File file) async {
  final db = NativeDatabase(file);
  final executor = DatabaseConnection(db);
  Future<void> run(String sql) => executor.executor.runCustom(sql, const []);

  await executor.executor.ensureOpen(_NoopUser());
  await run('CREATE TABLE channels (id TEXT NOT NULL PRIMARY KEY, '
      'name TEXT NOT NULL, kind TEXT NOT NULL, created_at INTEGER NOT NULL, '
      'topic TEXT, cursor INTEGER NOT NULL DEFAULT 0, '
      'last_read_seq INTEGER NOT NULL DEFAULT 0, '
      'is_personal_space INTEGER NOT NULL DEFAULT 0, '
      'dm_participant_id TEXT)');
  await run('CREATE TABLE messages (id TEXT NOT NULL PRIMARY KEY, '
      'channel_id TEXT NOT NULL, author_id TEXT, author_display_name TEXT, '
      'seq INTEGER NOT NULL, content TEXT NOT NULL, '
      'created_at INTEGER NOT NULL, edited_at INTEGER, '
      'pending INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0)');
  await run("INSERT INTO channels "
      "(id, name, kind, created_at, topic, cursor, last_read_seq, "
      "is_personal_space, dm_participant_id) "
      "VALUES ('chan-1', 'general', 'text', 900, NULL, 22, 3, 0, NULL)");
  await run("INSERT INTO messages "
      "(id, channel_id, author_id, author_display_name, seq, content, "
      "created_at, edited_at, pending, failed) VALUES "
      "('m-1', 'chan-1', 'user-1', 'Mara', 1, 'text the server replaced', "
      "1000, NULL, 0, 0)");
  await run('PRAGMA user_version = 6');
  await executor.executor.close();
}

class _NoopUser extends QueryExecutorUser {
  @override
  int get schemaVersion => 6;

  @override
  Future<void> beforeOpen(QueryExecutor e, OpeningDetails details) async {}
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v7');
    file = File('${dir.path}/slimm.sqlite');
    await _seedSchemaV6(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('a v6 cache is dropped too, not only a v2 one', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final rows = await db.select(db.messages).get();

    expect(rows, isEmpty,
        reason: 'a v6 client has taken v3 already and would keep stale text');
  });

  test('the cursor rewinds, or the dropped messages are never refetched',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final channel = await db.select(db.channels).getSingle();

    expect(channel.cursor, 0);
    expect(channel.lastReadSeq, 3, reason: 'only the message cache is dropped');
  });

  test('the new op cursor starts null rather than zero', () async {
    // Zero would claim to be caught up, which makes a sweep unrecoverable.
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final channel = await db.select(db.channels).getSingle();

    expect(channel.opCursor, null);
  });

  test('a v6 cache ends with all four message indexes after the rebuild',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name = 'messages' AND name LIKE 'messages_%'")
        .get();

    expect(
      rows.map((r) => r.read<String>('name')).toSet(),
      containsAll([
        'messages_channel_seq',
        'messages_author',
        'messages_pending',
        'messages_failed',
      ]),
    );
  });
}
