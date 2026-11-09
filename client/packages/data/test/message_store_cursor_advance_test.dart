// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A REST answer (a page opened from a channel, a send response) may be ahead
/// of what catch-up has fetched. Catch-up asks "after the cursor", so moving
/// the cursor over a gap strands the missing messages for good.
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

List<api.Message> _page(int from, int to) =>
    [for (var seq = from; seq <= to; seq++) _message(seq)];

/// A channel that catch-up has brought up to seq 100.
Future<MessageStore> _caughtUpTo100() async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 1),
  ]);
  await store.applyMessages(_page(1, 100));
  return store;
}

void main() {
  test('a page that starts past a gap is cached but leaves the cursor alone',
      () async {
    final store = await _caughtUpTo100();

    await store.applyMessages(_page(111, 160));

    expect(await store.cursorFor('c1'), 100);
    expect(await store.hasMessage('c1', 'm160'), isTrue);
    expect(
      (await store.allCursors()).single.afterSeq,
      100,
      reason: 'the next catch-up must still ask after 100',
    );
  });

  test('the same page moves the cursor once the gap is filled', () async {
    final store = await _caughtUpTo100();
    await store.applyMessages(_page(111, 160));

    await store.applyMessages(_page(101, 110), advance: CursorAdvance.always);
    await store.applyMessages(_page(111, 160));

    expect(await store.cursorFor('c1'), 160);
  });

  test('a page that joins the cursor moves it to the page head', () async {
    final store = await _caughtUpTo100();

    await store.applyMessages(_page(101, 160));
    expect(await store.cursorFor('c1'), 160);

    await store.applyMessages(_page(140, 180));
    expect(await store.cursorFor('c1'), 180);
  });

  test('a page that only overlaps what is held is not mistaken for a gap',
      () async {
    final store = await _caughtUpTo100();

    await store.applyMessages(_page(51, 120));

    expect(await store.cursorFor('c1'), 120);
  });

  test('an old message in the batch does not vouch for a gap above it',
      () async {
    final store = await _caughtUpTo100();

    await store.applyMessages([_message(5), ..._page(111, 160)]);

    expect(await store.cursorFor('c1'), 100);
  });

  test('a send response past a gap is stored without moving the cursor',
      () async {
    final store = await _caughtUpTo100();

    await store.applyMessage(_message(103));

    expect(await store.cursorFor('c1'), 100);
    expect(await store.hasMessage('c1', 'm103'), isTrue);
  });

  test('a send response that follows the cursor moves it', () async {
    final store = await _caughtUpTo100();

    await store.applyMessage(_message(101));

    expect(await store.cursorFor('c1'), 101);
  });

  test('the sync stream may move over a seq the server no longer lists',
      () async {
    final store = await _caughtUpTo100();

    await store.applyMessages(
      [_message(102), _message(103)],
      advance: CursorAdvance.always,
    );

    expect(await store.cursorFor('c1'), 103);
  });

  test('a channel that holds nothing yet adopts the page head', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 1),
    ]);

    await store.applyMessages(_page(951, 1000));

    expect(await store.cursorFor('c1'), 1000);
  });

  test('a mention past a gap is still remembered for the inbox', () async {
    final store = await _caughtUpTo100();

    await store.applyMessage(_message(130, mentionsMe: true));

    final channel = (await store.allChannels()).single;
    expect(channel.cursor, 100);
    expect(channel.mentionedSeq, 130);
  });
}
