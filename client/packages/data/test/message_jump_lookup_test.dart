// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [MessageStore.hasMessage], [MessageStore.transcriptDepthOf] and
/// [MessageStore.oldestLocalSeq] and [MessageStore.oldestSeqInWindow]: the
/// direct-database reads a message jump
/// pages history backwards with, with no transcript or channel screen
/// involved.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message({
  required String id,
  required int seq,
  String channelId = 'chan-1',
}) =>
    api.Message(
      id: id,
      channelId: channelId,
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: 'hello $seq',
      createdAt: seq * 1000,
      editedAt: null,
    );

void main() {
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() async {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(
        id: 'chan-1',
        name: 'general',
        kind: 'text',
        createdAt: 1,
      ),
    ]);
  });

  tearDown(() => db.close());

  test('hasMessage is true only for a row actually held for that channel',
      () async {
    await store.applyMessage(_message(id: 'm5', seq: 5));

    expect(await store.hasMessage('chan-1', 'm5'), isTrue);
    expect(
      await store.hasMessage('chan-1', 'does-not-exist'),
      isFalse,
      reason: 'an id nothing wrote must not read as present',
    );
    expect(
      await store.hasMessage('chan-2', 'm5'),
      isFalse,
      reason: 'a message from a different channel is not this one',
    );
  });

  test('oldestLocalSeq is the smallest delivered seq, ignoring pending rows',
      () async {
    await store.applyMessages([
      _message(id: 'm10', seq: 10),
      _message(id: 'm20', seq: 20),
      _message(id: 'm30', seq: 30),
    ]);
    await store.addPending(
      id: 'p1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'not sent yet',
    );

    expect(
      await store.oldestLocalSeq('chan-1'),
      10,
      reason:
          'a pending row carries seq 0, the lowest value there is, and must '
          'not read as the channel\'s oldest delivered message',
    );
  });

  test('oldestLocalSeq is null for a channel with nothing delivered yet',
      () async {
    expect(await store.oldestLocalSeq('chan-1'), isNull);
  });

  test('transcriptDepthOf counts the rows the window must reach', () async {
    await store.applyMessages([
      for (var seq = 10; seq <= 50; seq += 10) _message(id: 'm$seq', seq: seq),
    ]);
    await store.addPending(
      id: 'p1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'not sent yet',
    );

    expect(
      await store.transcriptDepthOf('chan-1', 'm50'),
      2,
      reason: 'the unsent row sits ahead of the newest delivered one',
    );
    expect(await store.transcriptDepthOf('chan-1', 'm20'), 5);
    expect(await store.transcriptDepthOf('chan-1', 'm10'), 6);
    expect(await store.transcriptDepthOf('chan-1', 'p1'), 1);
    expect(await store.transcriptDepthOf('chan-1', 'gone'), isNull);
    expect(await store.transcriptDepthOf('chan-2', 'm50'), isNull);
  });

  test('oldestSeqInWindow is where a window of that many rows ends', () async {
    await store.applyMessages([
      for (var seq = 10; seq <= 50; seq += 10) _message(id: 'm$seq', seq: seq),
      _message(id: 'other', seq: 5, channelId: 'chan-2'),
    ]);
    await store.addPending(
      id: 'p1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'not sent yet',
    );

    expect(await store.oldestSeqInWindow('chan-1', 1), 50);
    expect(await store.oldestSeqInWindow('chan-1', 3), 30);
    expect(
      await store.oldestSeqInWindow('chan-1', 200),
      10,
      reason: 'a window larger than the channel reaches its oldest row, '
          'never the unsent row\'s zero',
    );
    expect(await store.oldestSeqInWindow('chan-3', 200), isNull);
  });
}
