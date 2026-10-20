// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A removed channel takes its personal canvas layout with it, and the newest
/// message time follows the transcript rather than a lagging cursor.
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

  test('the newest message time tracks the transcript', () async {
    final seen = <int?>[];
    final sub = store.watchNewestMessageAt('c1').listen(seen.add);
    addTearDown(sub.cancel);
    await store.applyMessage(_message('m1', 1, 100));
    await store.applyMessage(_message('m2', 2, 200));
    await pumpEventQueue();
    expect(seen.last, 200);
    expect(seen.toSet(), containsAll(<int?>[200]));
  });
}
