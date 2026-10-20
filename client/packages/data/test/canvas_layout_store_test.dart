// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A viewer's canvas layouts in the local store: they come back after the
/// process is gone, stay per channel, stay bounded, and are wiped with the cache.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_data/src/database.dart' show ChannelsCompanion;

Future<void> _channel(SlimmDatabase db, String id) =>
    db.into(db.channels).insert(
          ChannelsCompanion.insert(
            id: id,
            name: id,
            kind: 'voice',
            createdAt: 1,
          ),
        );

void main() {
  late SlimmDatabase db;
  late CanvasLayoutStore store;

  setUp(() {
    db = SlimmDatabase(NativeDatabase.memory());
    store = CanvasLayoutStore(db);
  });
  tearDown(() => db.close());

  test('a saved layout reads back and a later save replaces it', () async {
    await store.save('c1', 'one', now: 1);
    await store.save('c1', 'two', now: 2);

    expect(await store.load('c1'), 'two');
  });

  test('each channel keeps its own', () async {
    await store.save('c1', 'one', now: 1);
    await store.save('c2', 'two', now: 2);

    expect(await store.load('c1'), 'one');
    expect(await store.load('c2'), 'two');
    expect(await store.load('c3'), isNull);
  });

  test('survives closing the database and opening the file again', () async {
    final dir = await Directory.systemTemp.createTemp('slimm-canvas-layout');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/slimm.sqlite');
    final first = SlimmDatabase(NativeDatabase(file));
    await CanvasLayoutStore(first).save('c1', 'kept', now: 1);
    await first.close();

    final second = SlimmDatabase(NativeDatabase(file));
    addTearDown(second.close);

    expect(await CanvasLayoutStore(second).load('c1'), 'kept');
  });

  test('delete forgets one channel only', () async {
    await store.save('c1', 'one', now: 1);
    await store.save('c2', 'two', now: 2);
    await store.delete('c1');

    expect(await store.load('c1'), isNull);
    expect(await store.load('c2'), 'two');
  });

  test('a channel this account no longer has is pruned on the next save',
      () async {
    await _channel(db, 'live');
    await _channel(db, 'other');
    await store.save('gone', 'x', now: 1);
    await store.save('live', 'y', now: 2);

    expect(await store.load('gone'), isNull);
    expect(await store.load('live'), 'y');
  });

  test('an empty channel list prunes nothing', () async {
    await store.save('c1', 'one', now: 1);
    await store.save('c2', 'two', now: 2);

    expect(await store.load('c1'), 'one');
  });

  test('the oldest layouts go once past the cap', () async {
    for (var i = 0; i < canvasLayoutsCap + 5; i++) {
      await store.save('c$i', 'l$i', now: i);
    }

    expect(await store.load('c0'), isNull);
    expect(await store.load('c4'), isNull);
    expect(await store.load('c5'), 'l5');
    expect(await store.load('c${canvasLayoutsCap + 4}'), isNotNull);
  });

  test('clearing the cache takes the layouts with it', () async {
    await store.save('c1', 'one', now: 1);
    await MessageStore(db).clear();

    expect(await store.load('c1'), isNull);
  });
}
