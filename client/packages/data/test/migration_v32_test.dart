// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-32 migration, which adds `channels.roomLobbyId` so the
/// rail can list a temporary room under its lobby (decision 0065).
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

Future<void> _v31WithRows(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.customStatement('ALTER TABLE channels DROP COLUMN room_lobby_id');
  await db.customStatement('PRAGMA user_version = 31');
  await db.customStatement(
    'INSERT INTO channels (id, name, kind, created_at, room_owner_id) '
    "VALUES ('room', 'alice''s room', 'voice', 1, 'alice')",
  );
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v32');
    file = File('${dir.path}/slimm.sqlite');
    await _v31WithRows(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client keeps its rooms until the next refresh', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final room = await MessageStore(db).channelRow('room');

    expect(room!.roomOwnerId, 'alice');
    expect(room.roomLobbyId, isNull);
  });

  test('a refresh after the upgrade records the room\'s lobby', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);

    await store.upsertChannels(const [
      api.Channel(
        id: 'room',
        name: "alice's room",
        kind: 'voice',
        createdAt: 1,
        roomOwnerId: 'alice',
        roomLobbyId: 'lobby',
      ),
    ]);

    expect((await store.channelRow('room'))!.roomLobbyId, 'lobby');
  });
}
