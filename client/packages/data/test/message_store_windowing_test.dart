// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for message windowing, reverse ordering, and pending send placement.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message({
  required String id,
  String channelId = 'chan-1',
  String? authorId = 'user-1',
  String? authorDisplayName = 'User One',
  int seq = 1,
  String content = 'hello',
  int createdAt = 1000,
  int? editedAt,
}) =>
    api.Message(
      id: id,
      channelId: channelId,
      authorId: authorId,
      authorDisplayName: authorDisplayName,
      seq: seq,
      content: content,
      createdAt: createdAt,
      editedAt: editedAt,
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

  /// The window is the newest rows, not the oldest. This ordered `seq`
  /// ascending under the same limit, so past the limit the transcript was
  /// pinned to the first messages ever synced and every later arrival was
  /// invisible - and the read marker froze with it, since the screen takes the
  /// newest row it is handed as the newest there is. No test passed a `limit`
  /// at all, which is how it survived.
  test('watchChannel windows the newest messages, not the oldest', () async {
    for (var seq = 1; seq <= 5; seq++) {
      await store
          .applyMessage(_message(id: 'm$seq', seq: seq, createdAt: seq * 1000));
    }

    final rows = await store.watchChannel('chan-1', limit: 3).first;
    expect(
      rows.map((m) => m.seq),
      [3, 4, 5],
      reason: 'the newest three, still ascending for the transcript to render',
    );
  });

  /// The schema says a local-only row's `seq` of 0 makes pending sends "sort
  /// last". Zero is the lowest value, so ascending put them first - at the top
  /// of the transcript, permanently for a failed send, since `markFailed`
  /// leaves the zero in place while the composer scrolls to the other end.
  test('a pending send sorts after every delivered message', () async {
    await store.applyMessage(_message(id: 'm1', seq: 1, createdAt: 1000));
    await store.applyMessage(_message(id: 'm2', seq: 2, createdAt: 2000));
    await store.addPending(
      id: 'p1',
      channelId: 'chan-1',
      authorId: 'me',
      content: 'not sent yet',
    );

    final rows = await store.watchChannel('chan-1').first;
    expect(rows.map((m) => m.id), ['m1', 'm2', 'p1']);

    await store.markFailed('p1', reason: 'unreachable');
    final afterFailure = await store.watchChannel('chan-1').first;
    expect(
      afterFailure.map((m) => m.id),
      ['m1', 'm2', 'p1'],
      reason: 'markFailed leaves seq at 0, so a failed send must stay put',
    );
  });

  /// A pending send survives a full window. The ordering has to happen before
  /// the limit, not after it in Dart, or a channel already holding `limit`
  /// delivered rows cuts the sender's own unsent message off the end.
  test('a pending send survives a full window', () async {
    for (var seq = 1; seq <= 4; seq++) {
      await store
          .applyMessage(_message(id: 'm$seq', seq: seq, createdAt: seq * 1000));
    }
    await store.addPending(
      id: 'p1',
      channelId: 'chan-1',
      authorId: 'me',
      content: 'not sent yet',
    );

    final rows = await store.watchChannel('chan-1', limit: 2).first;
    expect(
      rows.map((m) => m.id),
      ['m4', 'p1'],
      reason:
          'the newest delivered row and the unsent one, never the unsent one '
          'dropped for being over the limit',
    );
  });
}
