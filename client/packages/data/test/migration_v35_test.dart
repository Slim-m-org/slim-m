// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-35 migration, which records whether a channel has a board
/// and a call, so a cold start draws the right controls before the first listing.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_data/src/rail_channel.dart';

Future<void> _v34WithVoice(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await MessageStore(db).upsertChannels([
    const api.Channel(id: 'v1', name: 'lounge', kind: 'voice', createdAt: 1),
  ]);
  await db.customStatement('ALTER TABLE channels DROP COLUMN canvas_enabled');
  await db.customStatement('ALTER TABLE channels DROP COLUMN voice_enabled');
  await db.customStatement('PRAGMA user_version = 34');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v35');
    file = File('${dir.path}/slimm.sqlite');
    await _v34WithVoice(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client keeps its rows and reads null as an older server',
      () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = (await MessageStore(db).channelRow('v1'))!;
    expect((row.name, row.canvasEnabled, row.voiceEnabled),
        ('lounge', null, null));
    expect((row.hasCanvas, row.hostsCall), (true, true));
  });

  test('both flags round trip through an upsert', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels(const [
      api.Channel(
        id: 'v1',
        name: 'lounge',
        kind: 'voice',
        createdAt: 1,
        canvasEnabled: false,
        voiceEnabled: true,
      ),
      api.Channel(
        id: 'c1',
        name: 'designs',
        kind: 'canvas',
        createdAt: 2,
        canvasEnabled: true,
        voiceEnabled: false,
      ),
    ]);
    final voice = (await store.channelRow('v1'))!;
    final canvas = (await store.channelRow('c1'))!;
    expect((voice.hasCanvas, voice.hostsCall), (false, true));
    expect((canvas.isCanvasChannel, canvas.hasCanvas, canvas.hostsCall),
        (true, true, false));
  });

  test('a flag change moves the rail key', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);
    final before = railChannelKey((await store.channelRow('v1'))!);
    await store.upsertChannels(const [
      api.Channel(
        id: 'v1',
        name: 'lounge',
        kind: 'voice',
        createdAt: 1,
        canvasEnabled: false,
        voiceEnabled: true,
      ),
    ]);
    expect(railChannelKey((await store.channelRow('v1'))!), isNot(before));
  });
}
