// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `MessageStore.watchRailChannels` (CP8): the channel rail rebuilds on every
/// incoming message because `watchChannels` re-emits on any write to the
/// `channels` table, including a message's cursor advance and an edit's op
/// cursor, neither of which the rail draws. `watchRailChannels` dedupes those
/// away, so this pins the two directions: a write nothing on screen reads
/// must not produce a second emission, and a write that does change what the
/// rail would draw must still produce one.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message(String id, String channelId, int seq) => api.Message(
      id: id,
      channelId: channelId,
      authorId: 'alice',
      authorDisplayName: 'Alice',
      seq: seq,
      content: 'message $seq',
      createdAt: seq * 1000,
      editedAt: null,
    );

void main() {
  late SlimmDatabase db;
  late MessageStore store;
  late List<List<Channel>> snapshots;

  setUp(() async {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(
          id: 'chan-1', name: 'general', kind: 'text', createdAt: 1),
      const api.Channel(
          id: 'chan-2', name: 'other', kind: 'text', createdAt: 2),
    ]);
    snapshots = [];
    final sub = store.watchRailChannels().listen(snapshots.add);
    addTearDown(sub.cancel);
    // Let the initial snapshot land before the write each test is about.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    snapshots.clear();
  });

  tearDown(() => db.close());

  test('setOpCursor never re-emits: the rail draws no op cursor at all',
      () async {
    await store.setOpCursor('chan-1', 3);
    await store.setOpCursor('chan-1', 7);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(snapshots, isEmpty);
  });

  test(
      'a second message into an already-unread channel does not re-emit: '
      'the badge is already on', () async {
    // A real display change (read -> unread), deliberately not asserted away.
    await store.applyMessage(_message('m1', 'chan-1', 1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    snapshots.clear();

    // The cursor advances again, but the unread dot was already lit.
    await store.applyMessage(_message('m2', 'chan-1', 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(snapshots, isEmpty);
  });

  test('a message into a caught-up channel does re-emit: the badge lights',
      () async {
    await store.setReadMarker('chan-1', 5);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    snapshots.clear();

    await store.applyMessage(_message('m1', 'chan-1', 6));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(snapshots, hasLength(1));
    final chan1 = snapshots.single.firstWhere((c) => c.id == 'chan-1');
    expect(chan1.cursor > chan1.lastReadSeq, isTrue);
  });

  test('renaming a channel does re-emit', () async {
    await store.upsertChannels([
      const api.Channel(
          id: 'chan-1', name: 'renamed', kind: 'text', createdAt: 1),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(snapshots, hasLength(1));
    expect(
        snapshots.single.firstWhere((c) => c.id == 'chan-1').name, 'renamed');
  });

  test('reordering a channel does re-emit', () async {
    await store.upsertChannels([
      const api.Channel(
        id: 'chan-1',
        name: 'general',
        kind: 'text',
        createdAt: 1,
        position: 5,
      ),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(snapshots, hasLength(1));
    expect(snapshots.single.firstWhere((c) => c.id == 'chan-1').position, 5);
  });

  test('flipping a channel to restricted does re-emit: the rail draws a lock',
      () async {
    await store.upsertChannels([
      const api.Channel(
        id: 'chan-1',
        name: 'general',
        kind: 'text',
        createdAt: 1,
        restricted: true,
      ),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(snapshots, hasLength(1));
    expect(
        snapshots.single.firstWhere((c) => c.id == 'chan-1').restricted, true);
  });
}
