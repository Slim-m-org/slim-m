// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `MessageStore.watchChannel` re-selects on every write to `messages`; the
/// open transcript must only hear about writes that change its own window.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message(String id, String channelId, int seq, {String? text}) =>
    api.Message(
      id: id,
      channelId: channelId,
      authorId: 'alice',
      authorDisplayName: 'Alice',
      seq: seq,
      content: text ?? 'message $seq',
      createdAt: seq * 1000,
      editedAt: null,
    );

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late SlimmDatabase db;
  late MessageStore store;
  late List<List<Message>> emissions;

  setUp(() async {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'open', name: 'open', kind: 'text', createdAt: 1),
      const api.Channel(id: 'other', name: 'other', kind: 'text', createdAt: 2),
    ]);
    await store.applyMessage(_message('m1', 'open', 1));
    emissions = [];
    final sub = store.watchChannel('open').listen(emissions.add);
    addTearDown(sub.cancel);
    await _settle();
    emissions.clear();
  });

  tearDown(() => db.close());

  test('20 messages landing in another channel emit nothing', () async {
    for (var i = 1; i <= 20; i++) {
      await store.applyMessage(_message('o$i', 'other', i));
    }
    await _settle();

    expect(emissions, isEmpty);
  });

  test('a new message in the open channel emits once', () async {
    await store.applyMessage(_message('m2', 'open', 2));
    await _settle();

    expect(emissions.length, 1);
    expect(emissions.single.map((m) => m.id), ['m1', 'm2']);
  });

  test('an edit of a visible message emits', () async {
    await store.applyMessage(_message('m1', 'open', 1, text: 'edited'));
    await _settle();

    expect(emissions.length, 1);
    expect(emissions.single.single.content, 'edited');
  });
}
