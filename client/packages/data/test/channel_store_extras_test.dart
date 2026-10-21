// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A removed channel takes its personal canvas layout with it, and the cursor
/// watch emits only when a cursor moves.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message(String id, int seq, int createdAt) => api.Message(
      id: id,
      channelId: 'c1',
      authorId: 'u',
      authorDisplayName: 'U',
      seq: seq,
      content: 'hi',
      createdAt: createdAt,
      editedAt: null,
    );

void main() {
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
  });
  tearDown(() => db.close());

  test('removing a channel deletes its personal canvas layout', () async {
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'c1', kind: 'voice', createdAt: 1),
    ]);
    final layouts = CanvasLayoutStore(db);
    await layouts.save('c1', 'layout', now: 1);

    await store.removeChannel('c1');

    expect(await layouts.load('c1'), isNull);
  });

  test('pruning a channel from the list deletes its layout too', () async {
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'c1', kind: 'voice', createdAt: 1),
    ]);
    final layouts = CanvasLayoutStore(db);
    await layouts.save('c1', 'layout', now: 1);

    await store.replaceChannels(const []);

    expect(await layouts.load('c1'), isNull);
  });

  test('the channel cursors follow each message and stay quiet otherwise',
      () async {
    await store.upsertChannels([
      for (final id in ['c1', 'c2'])
        api.Channel(id: id, name: id, kind: 'text', createdAt: 1),
    ]);
    final seen = <Map<String, int>>[];
    final sub = store.watchChannelCursors().listen(seen.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(seen.last, {'c1': 0, 'c2': 0});

    await store.applyMessage(_message('m1', 1, 100));
    await store.applyMessage(_message('m2', 2, 200));
    await pumpEventQueue();
    expect(seen.last, {'c1': 2, 'c2': 0});

    final emitted = seen.length;
    await store.setReadMarker('c1', 2);
    await store.setOpCursor('c1', 5);
    await pumpEventQueue();
    expect(seen, hasLength(emitted), reason: 'no cursor moved');
  });
}
