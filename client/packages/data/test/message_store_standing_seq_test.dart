// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message deleted before it was read must not leave its channel unread: the
/// sync cursor never moves back, so unread is measured against `standingSeq`.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message(int seq, {bool mentionsMe = false}) => api.Message(
      id: 'm$seq',
      channelId: 'c1',
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: 'hello $seq',
      createdAt: 1000,
      editedAt: null,
      mentionsMe: mentionsMe,
    );

Future<MessageStore> _store() async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 1),
  ]);
  return store;
}

Future<Channel> _row(MessageStore store) async =>
    (await store.allChannels()).singleWhere((c) => c.id == 'c1');

void main() {
  test('deleting the only unread message leaves nothing unread', () async {
    final store = await _store();
    await store.applyMessage(_message(1));
    await store.setReadMarker('c1', 1);
    await store.applyMessage(_message(2));
    expect((await _row(store)).standingSeq, 2);

    await store.discard('m2');

    final row = await _row(store);
    expect(row.cursor, 2, reason: 'the sync cursor never moves back');
    expect(row.standingSeq, 1);
    expect(row.standingSeq > row.lastReadSeq, isFalse);
  });

  test('deleting an older unread message keeps the newer one unread', () async {
    final store = await _store();
    await store.applyMessages([_message(1), _message(2), _message(3)]);
    await store.setReadMarker('c1', 1);

    await store.discard('m2');

    expect((await _row(store)).standingSeq, 3);
  });

  test('a deleted mention stops lighting the channel as mentioned', () async {
    final store = await _store();
    await store.applyMessage(_message(1));
    await store.setReadMarker('c1', 1);
    await store.applyMessage(_message(2, mentionsMe: true));
    expect((await _row(store)).mentionedSeq, 2);

    await store.discard('m2');

    final row = await _row(store);
    expect(row.mentionedSeq > row.lastReadSeq, isFalse);
    expect(row.standingSeq > row.lastReadSeq, isFalse);
  });

  test('deleting every message held drops the standing seq to nothing',
      () async {
    final store = await _store();
    await store.applyMessage(_message(4));

    await store.discard('m4');

    expect((await _row(store)).standingSeq, 0);
  });

  test('a message arriving past a gap still counts as standing', () async {
    final store = await _store();
    await store.applyMessages([_message(1), _message(2)]);
    await store.applyMessage(_message(9));

    final row = await _row(store);
    expect(row.cursor, 2);
    expect(row.standingSeq, 9);
  });

  test('a pending send that is discarded changes nothing', () async {
    final store = await _store();
    await store.applyMessage(_message(3));

    await store.discard('not-stored');

    expect((await _row(store)).standingSeq, 3);
  });
}
