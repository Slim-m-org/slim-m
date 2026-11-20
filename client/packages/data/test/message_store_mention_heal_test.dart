// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mention cursor only the server can correct: one naming no held message
/// that still mentions this account asks for the sync marker, and the marker
/// lowers it then and only then.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message(int seq, {bool mentionsMe = false, int? editedAt}) =>
    api.Message(
      id: 'm$seq',
      channelId: 'c1',
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: 'hello $seq',
      createdAt: 1000,
      editedAt: editedAt,
      mentionsMe: mentionsMe,
    );

/// A channel read up to seq 80.
Future<MessageStore> _readTo80() async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 1),
  ]);
  await store.setReadMarker('c1', 80);
  return store;
}

Future<bool> _asks(MessageStore store) async =>
    (await store.allCursors()).single.checkMention;

Future<int> _mentioned(MessageStore store) async =>
    (await store.channelRow('c1'))!.mentionedSeq;

void main() {
  test('a cursor on a message never held asks, and the marker lowers it',
      () async {
    final store = await _readTo80();
    await store.advanceMentionCursor('c1', 90);
    expect(await _asks(store), isTrue);

    await store.healMentionCursor('c1', 0);
    expect(await _mentioned(store), 0);
  });

  test('a held mention edited away asks, and the marker lowers it', () async {
    final store = await _readTo80();
    await store.applyMessages([_message(95, mentionsMe: true)]);
    expect(await _asks(store), isFalse);

    await store.applyEdited(_message(95, editedAt: 2000));
    expect(await _asks(store), isTrue);
    await store.healMentionCursor('c1', 0);
    expect(await _mentioned(store), 0);
  });

  test('a mention edited away in a catch-up op asks too', () async {
    final store = await _readTo80();
    await store.applyMessages([_message(95, mentionsMe: true)]);
    expect(await _asks(store), isFalse);

    await store.applyEdit('m95', 'no mention now', 2000);

    expect(await _asks(store), isTrue);
  });

  test('a held mention neither asks nor gives way to an older marker',
      () async {
    final store = await _readTo80();
    await store.applyMessages([_message(95, mentionsMe: true)]);

    await store.healMentionCursor('c1', 0);
    expect(await _asks(store), isFalse);
    expect(await _mentioned(store), 95);
  });

  test('a mention already read never asks', () async {
    final store = await _readTo80();
    await store.advanceMentionCursor('c1', 70);
    expect(await _asks(store), isFalse);
  });
}
