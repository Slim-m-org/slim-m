// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A forward's origin survives the round trip through local storage, on both
/// write paths.
///
/// `applyMessage` and the batch behind `applyMessages` build the same row and
/// are reached by different delivery routes - live push and catch-up - so a
/// forward that only one of them persisted would render complete when it
/// arrived live and lose its origin on the next catch-up over the same range.
/// That is exactly the shape of the bug an image once had before attachments
/// rode along on the live frame, so both paths are pinned here.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

const _origin = api.ForwardedMessage(
  messageId: 'm-origin',
  channelId: 'chan-2',
  authorId: 'user-2',
  authorDisplayName: 'Alice',
  authorAvatarUpdatedAt: 77,
  createdAt: 10,
  content: 'the original text',
);

api.Message _forward({api.ForwardedMessage? forwarded = _origin}) =>
    api.Message(
      id: 'm1',
      channelId: 'chan-1',
      authorId: 'user-1',
      authorDisplayName: 'Bob',
      seq: 1,
      content: 'look at this',
      createdAt: 1000,
      editedAt: null,
      forwarded: forwarded,
    );

void main() {
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() async {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(
          id: 'chan-1', name: 'general', kind: 'text', createdAt: 1),
      const api.Channel(
          id: 'chan-2', name: 'other', kind: 'text', createdAt: 2),
    ]);
  });

  tearDown(() => db.close());

  test('a forward stored live keeps its whole origin', () async {
    await store.applyMessage(_forward());

    final stored = (await store.watchChannel('chan-1').first).single;

    expect(stored.content, 'look at this', reason: "the forwarder's own note");
    expect(stored.forwarded, _origin.toLocal());
  });

  test('a forward stored by catch-up keeps its whole origin', () async {
    await store.applyMessages([_forward()]);

    final stored = (await store.watchChannel('chan-1').first).single;

    expect(stored.forwarded, _origin.toLocal());
  });

  test('a later frame that omits the forward leaves it alone', () async {
    await store.applyMessage(_forward());
    // What an edit looks like: same id, new content, nothing said about the forward.
    await store.applyMessage(
      const api.Message(
        id: 'm1',
        channelId: 'chan-1',
        authorId: 'user-1',
        authorDisplayName: 'Bob',
        seq: 1,
        content: 'a better note',
        createdAt: 1000,
        editedAt: 2000,
      ),
    );

    final stored = (await store.watchChannel('chan-1').first).single;

    expect(stored.content, 'a better note');
    expect(
      stored.forwarded,
      _origin.toLocal(),
      reason: 'nothing un-forwards a message, so silence cannot mean removed',
    );
  });

  test('an ordinary message reads back as forwarding nothing', () async {
    await store.applyMessage(_forward(forwarded: null));

    final stored = (await store.watchChannel('chan-1').first).single;

    expect(stored.forwarded, null);
  });

  test('a removed snapshot round trips as removed', () async {
    const removed = api.ForwardedMessage(
      messageId: 'm-origin',
      channelId: 'chan-2',
      authorId: null,
      authorDisplayName: null,
      authorAvatarUpdatedAt: null,
      createdAt: 10,
      content: '',
      removed: true,
    );
    await store.applyMessage(_forward(forwarded: removed));

    final stored = (await store.watchChannel('chan-1').first).single;

    expect(stored.forwarded, removed.toLocal());
    expect(stored.forwarded!.removed, isTrue);
  });

  test('removeForwardSnapshot blanks the origin and keeps the note', () async {
    await store.applyMessage(_forward());

    await store.removeForwardSnapshot('m1');

    final stored = (await store.watchChannel('chan-1').first).single;
    expect(stored.content, 'look at this');
    expect(stored.forwarded!.removed, isTrue);
    expect(stored.forwarded!.content, '');
    expect(stored.forwarded!.authorDisplayName, isNull);
  });
}

/// The same values as the local DTO, so the round trip can be asserted whole
/// rather than field by field - a per-field check silently passes for any
/// column a future write path forgets.
extension on api.ForwardedMessage {
  ForwardedMessage toLocal() => ForwardedMessage(
        messageId: messageId,
        channelId: channelId,
        authorId: authorId,
        authorDisplayName: authorDisplayName,
        authorAvatarUpdatedAt: authorAvatarUpdatedAt,
        createdAt: createdAt,
        content: content,
        removed: removed,
      );
}
