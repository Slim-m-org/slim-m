// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `MessageStore.watchChannelRow` re-selects on every write to `channels`; the
/// screen and shell panes watching one channel must only hear about changes to
/// that channel's own row.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import 'support/wait_for.dart';

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
  late List<Channel?> emissions;

  setUp(() async {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'open', name: 'open', kind: 'text', createdAt: 1),
      const api.Channel(id: 'other', name: 'other', kind: 'text', createdAt: 2),
    ]);
    emissions = [];
    final sub = store.watchChannelRow('open').listen(emissions.add);
    addTearDown(sub.cancel);
    await waitFor(() => emissions.isNotEmpty);
    emissions.clear();
  });

  tearDown(() => db.close());

  test('messages landing in another channel emit nothing', () async {
    for (var i = 1; i <= 5; i++) {
      await store.applyMessage(_message('o$i', 'other', i));
    }
    await store.setReadMarker('other', 3);
    await store.setOpCursor('other', 9);
    await pumpEventQueue();
    await store.upsertChannels([
      const api.Channel(
          id: 'open', name: 'sentinel', kind: 'text', createdAt: 1),
    ]);
    await waitFor(() => emissions.isNotEmpty);

    expect(emissions.map((c) => c!.name), ['sentinel']);
  });

  test('a message in the watched channel emits its advanced cursor', () async {
    await store.applyMessage(_message('m1', 'open', 1));
    await waitFor(() => emissions.isNotEmpty);

    expect(emissions, hasLength(1));
    expect(emissions.single!.cursor, 1);
  });

  test('renaming the watched channel emits', () async {
    await store.upsertChannels([
      const api.Channel(
          id: 'open', name: 'renamed', kind: 'text', createdAt: 1),
    ]);
    await waitFor(() => emissions.isNotEmpty);

    expect(emissions.single!.name, 'renamed');
  });
}
