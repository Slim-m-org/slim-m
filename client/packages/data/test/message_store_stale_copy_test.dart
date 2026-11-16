// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An older copy of a message can arrive after the edit or delete that
/// superseded it: a page already in flight, or a frame held during a connect.
/// Storing it would undo the op for good, since the op cursor is already past.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message(
  int seq, {
  String content = 'first draft',
  int? editedAt,
  api.ForwardedMessage? forwarded,
}) =>
    api.Message(
      id: 'm$seq',
      channelId: 'c1',
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: content,
      createdAt: 1000,
      editedAt: editedAt,
      forwarded: forwarded,
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

Future<Message?> _held(MessageStore store, String id) async {
  final rows = await store.channelSnapshot('c1');
  return rows.where((m) => m.id == id).firstOrNull;
}

void main() {
  test('a page read before a delete does not bring the message back', () async {
    final store = await _store();
    await store.applyMessages([_message(1), _message(2)]);

    await store.discard('m2');
    await store.applyMessages([_message(1), _message(2)]);

    expect(await _held(store, 'm2'), isNull);
    expect(await _held(store, 'm1'), isNotNull);
  });

  test('a copy of a message deleted before it was ever held is not stored',
      () async {
    final store = await _store();

    await store.discard('m2');
    await store.applyMessage(_message(2));

    expect(await _held(store, 'm2'), isNull);
  });

  test('a page read before an edit does not put the old text back', () async {
    final store = await _store();
    await store.applyMessage(_message(2));
    await store.applyEdited(
      _message(2, content: 'second draft', editedAt: 2000),
    );

    await store.applyMessages([_message(2)]);

    expect((await _held(store, 'm2'))!.content, 'second draft');
    expect((await _held(store, 'm2'))!.editedAt, 2000);
  });

  test('an older edit does not replace a newer one', () async {
    final store = await _store();
    await store.applyMessage(_message(2, content: 'third', editedAt: 3000));

    await store.applyMessage(_message(2, content: 'second', editedAt: 2000));

    expect((await _held(store, 'm2'))!.content, 'third');
  });

  test('a stale copy still counts as applied for the sync cursor', () async {
    final store = await _store();
    await store.applyMessage(_message(1));
    await store.applyMessage(_message(3, content: 'edited', editedAt: 2000));
    expect(await store.cursorFor('c1'), 1, reason: 'seq 2 is still owed');

    await store.applyMessages([_message(3)], advance: CursorAdvance.always);

    expect(await store.cursorFor('c1'), 3);
    expect((await _held(store, 'm3'))!.content, 'edited');
  });

  test('a live edit of a message not held stores no row', () async {
    final store = await _store();
    await store.applyMessages([_message(8), _message(9)]);

    await store.applyEdited(_message(2, content: 'edited', editedAt: 2000));

    expect(await _held(store, 'm2'), isNull);
    expect(await store.oldestLocalSeq('c1'), 8);
  });

  test('an edit seen before its message is held is carried by the row',
      () async {
    final store = await _store();
    await store.applyEdited(_message(2, content: 'edited', editedAt: 2000));

    await store.applyMessages([_message(2)]);

    expect((await _held(store, 'm2'))!.content, 'edited');
    expect((await _held(store, 'm2'))!.editedAt, 2000);
  });

  test('an op edit of a message not held is carried by the row too', () async {
    final store = await _store();
    await store.applyEdit('m2', 'edited', 2000);

    await store.applyMessage(_message(2));

    expect((await _held(store, 'm2'))!.content, 'edited');
  });

  test('a discarded unsent message can still land when the send got through',
      () async {
    final store = await _store();
    await store.addPending(
      id: 'm2',
      channelId: 'c1',
      authorId: 'user-1',
      content: 'first draft',
    );

    await store.discard('m2');
    await store.applyMessage(_message(2));

    expect(await _held(store, 'm2'), isNotNull);
  });

  test('a stale copy does not restore a forward whose original was removed',
      () async {
    final store = await _store();
    const snapshot = api.ForwardedMessage(
      messageId: 'origin',
      channelId: 'c9',
      authorId: 'user-2',
      authorDisplayName: 'User Two',
      authorAvatarUpdatedAt: null,
      createdAt: 500,
      content: 'the original text',
    );
    await store.applyMessage(_message(2, forwarded: snapshot));
    await store.removeForwardSnapshot('m2');

    await store.applyMessages([_message(2, forwarded: snapshot)]);

    final forwarded = (await _held(store, 'm2'))!.forwarded!;
    expect(forwarded.removed, isTrue);
    expect(forwarded.content, isEmpty);
  });

  test('signing out forgets what was deleted', () async {
    final store = await _store();
    await store.discard('m2');

    await store.clear();
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 1),
    ]);
    await store.applyMessage(_message(2));

    expect(await _held(store, 'm2'), isNotNull);
  });
}
