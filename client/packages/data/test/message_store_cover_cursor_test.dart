// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Covering a channel's cursor up to the server's head: the cursor moves over
/// messages that were deleted, and nothing a reader sees moves with it.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message(int seq) => api.Message(
      id: 'm$seq',
      channelId: 'c1',
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: 'message $seq',
      createdAt: 1000,
      editedAt: null,
    );

void main() {
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() async {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 1),
    ]);
  });

  tearDown(() => db.close());

  test('the cursor moves to the head', () async {
    await store.applyMessage(_message(1));

    await store.coverCursor('c1', 4);

    expect(await store.cursorFor('c1'), 4);
  });

  test('the cursor never moves back', () async {
    await store.applyMessages([_message(1), _message(2), _message(3)]);

    await store.coverCursor('c1', 2);

    expect(await store.cursorFor('c1'), 3);
  });

  test('the standing seq stays at the newest message held', () async {
    await store.applyMessage(_message(1));

    await store.coverCursor('c1', 4);

    expect((await store.channelRow('c1'))!.standingSeq, 1);
  });

  test('a channel whose every message was deleted does not read as unread',
      () async {
    await store.coverCursor('c1', 3);

    final row = (await store.channelRow('c1'))!;
    expect(row.standingSeq, 0);
    expect(row.standingSeq > row.lastReadSeq, isFalse);
  });

  test(
      'a page of older messages still lands after a first write moved the cursor',
      () async {
    await store.applyMessage(_message(3));
    expect(await store.cursorFor('c1'), 3);

    await store.applyMessages(
      [_message(1), _message(2)],
      advance: CursorAdvance.always,
    );

    final held = await store.channelSnapshot('c1');
    expect(held.map((m) => m.seq), unorderedEquals([1, 2, 3]));
  });

  test('the next message after a covered tail is contiguous', () async {
    await store.applyMessage(_message(1));
    await store.coverCursor('c1', 3);

    await store.applyMessage(_message(4));

    expect(await store.cursorFor('c1'), 4);
    expect((await store.channelRow('c1'))!.standingSeq, 4);
  });
}
