// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// CD1: `applyMessages` is the batched catch-up/scroll-back path. It was a loop
/// of `applyMessage`, each opening its own savepoint, select, upsert and cursor
/// read-write; it now reads colliding rows once, writes survivors in one batch,
/// and advances each channel's cursor once. The invariant that matters is that
/// the batch decides idempotency and ordering exactly as the single path does,
/// so the anchor test runs the same mixed batch through both and diffs the
/// result; the rest pin the individual rules for readability.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message({
  required String id,
  String channelId = 'chan-1',
  int seq = 1,
  String content = 'hello',
}) =>
    api.Message(
      id: id,
      channelId: channelId,
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: content,
      createdAt: 1000,
      editedAt: null,
    );

Future<MessageStore> _store() async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(
        id: 'chan-1', name: 'general', kind: 'text', createdAt: 1),
    const api.Channel(id: 'chan-2', name: 'other', kind: 'text', createdAt: 2),
  ]);
  return store;
}

Future<int> _cursor(MessageStore store, String channelId) async {
  final channels = await store.allChannels();
  return channels.firstWhere((c) => c.id == channelId).cursor;
}

/// (id, seq, content, pending) for each row in a channel, in read order.
Future<List<(String, int, String, bool)>> _rows(
  MessageStore store,
  String channelId,
) async {
  final rows = await store.watchChannel(channelId).first;
  return [
    for (final r in rows) (r.id, r.seq, r.content, r.pending),
  ];
}

void main() {
  test('the batch path matches applyMessage-in-loop for a mixed batch',
      () async {
    final loop = await _store();
    final batch = await _store();

    // Seed both identically: a newer stored m1, and a pending local m2.
    for (final s in [loop, batch]) {
      await s.applyMessage(_message(id: 'm1', seq: 10, content: 'newer'));
      await s.addPending(
        id: 'm2',
        channelId: 'chan-1',
        authorId: 'user-1',
        content: 'still typing',
      );
    }

    final messages = <api.Message>[
      _message(id: 'm3', seq: 3),
      _message(id: 'm1', seq: 4, content: 'stale'), // loses to stored seq 10
      _message(id: 'm2', seq: 5, content: 'server'), // replaces the pending row
      _message(id: 'm4', channelId: 'chan-2', seq: 2),
      _message(
          id: 'm4', channelId: 'chan-2', seq: 7, content: 'dup'), // higher wins
      _message(id: 'm6', seq: 4, content: 'first'),
      _message(id: 'm6', seq: 4, content: 'second'), // equal seq: later wins
      _message(id: 'm5', seq: 12),
    ];
    // The sync stream's policy, since this pins ordering rules and not what a gap does to the cursor.
    for (final m in messages) {
      await loop.applyMessage(m, advance: CursorAdvance.always);
    }
    await batch.applyMessages(messages, advance: CursorAdvance.always);

    for (final channel in ['chan-1', 'chan-2']) {
      expect(
        await _rows(batch, channel),
        await _rows(loop, channel),
        reason: '$channel rows must match the single-apply path exactly',
      );
      expect(
        await _cursor(batch, channel),
        await _cursor(loop, channel),
        reason: '$channel cursor must match the single-apply path exactly',
      );
    }
  });

  test('a stale message in the batch neither overwrites nor regresses',
      () async {
    final store = await _store();
    await store.applyMessage(_message(id: 'm1', seq: 10, content: 'newer'));

    await store.applyMessages([
      _message(id: 'm1', seq: 4, content: 'stale'),
      _message(id: 'm2', seq: 6),
    ]);

    expect(await _rows(store, 'chan-1'), [
      ('m2', 6, 'hello', false),
      ('m1', 10, 'newer', false),
    ]);
    expect(
      await _cursor(store, 'chan-1'),
      10,
      reason: 'the stale m1 must not drag the cursor back below where it was',
    );
  });

  test('a duplicate id within one batch keeps the highest seq', () async {
    final store = await _store();
    await store.applyMessages([
      _message(id: 'm1', seq: 2, content: 'lower'),
      _message(id: 'm1', seq: 9, content: 'higher'),
    ]);
    expect(await _rows(store, 'chan-1'), [('m1', 9, 'higher', false)]);
  });

  test('an equal-seq duplicate keeps the later copy, as a re-apply would',
      () async {
    // Never sent by a real server, but the batch must still match applyMessage-in-loop: an equal-seq re-apply overwrites rather than skips, so the last copy wins.
    final store = await _store();
    await store.applyMessages([
      _message(id: 'm1', seq: 5, content: 'first'),
      _message(id: 'm1', seq: 5, content: 'second'),
    ]);
    expect(await _rows(store, 'chan-1'), [('m1', 5, 'second', false)]);
  });

  test('each channel advances to its own greatest applied seq', () async {
    final store = await _store();
    await store.applyMessages([
      _message(id: 'a1', seq: 3),
      _message(id: 'a2', seq: 8),
      _message(id: 'b1', channelId: 'chan-2', seq: 2),
      _message(id: 'b2', channelId: 'chan-2', seq: 4),
    ]);
    expect(await _cursor(store, 'chan-1'), 8);
    expect(await _cursor(store, 'chan-2'), 4);
  });

  test('re-applying the same batch changes nothing', () async {
    final store = await _store();
    final page = [
      _message(id: 'm1', seq: 1),
      _message(id: 'm2', seq: 2),
    ];
    await store.applyMessages(page);
    await store.applyMessages(page);

    expect(await _rows(store, 'chan-1'), [
      ('m1', 1, 'hello', false),
      ('m2', 2, 'hello', false),
    ]);
    expect(await _cursor(store, 'chan-1'), 2);
  });

  test('an empty batch is a no-op', () async {
    final store = await _store();
    await store.applyMessages(const []);
    expect(await _rows(store, 'chan-1'), isEmpty);
    expect(await _cursor(store, 'chan-1'), 0);
  });
}
