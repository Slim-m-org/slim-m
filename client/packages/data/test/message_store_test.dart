// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the local store's two invariants: writes are idempotent by message
/// id, and a stale copy can never overwrite a newer one. Both delivery routes
/// (live push and catch-up) rely on those holding under any interleaving.
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

/// The cursor lives on the channel row itself; there is no dedicated reader.
Future<int> _cursorOf(MessageStore store, String channelId) async {
  final channels = await store.allChannels();
  return channels.firstWhere((c) => c.id == channelId).cursor;
}

Future<int> _lastReadSeqOf(MessageStore store, String channelId) async {
  final channels = await store.allChannels();
  return channels.firstWhere((c) => c.id == channelId).lastReadSeq;
}

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

  test('applying the same message twice stores it once', () async {
    final message = _message(id: 'm1', seq: 1);
    await store.applyMessage(message);
    // The same message can genuinely arrive twice: once live over the socket,
    // once from a catch-up covering the same range.
    await store.applyMessage(message);

    final rows = await store.watchChannel('chan-1').first;
    expect(rows, hasLength(1));
    expect(rows.single.id, 'm1');
  });

  test('a stale copy never overwrites a newer one', () async {
    await store.applyMessage(
      _message(id: 'm1', seq: 5, content: 'edited', editedAt: 2000),
    );
    // A late catch-up delivering the pre-edit version must not undo the edit.
    await store.applyMessage(_message(id: 'm1', seq: 3, content: 'original'));

    final rows = await store.watchChannel('chan-1').first;
    expect(rows.single.content, 'edited');
    expect(rows.single.seq, 5);
  });

  test('an edit at a higher seq does replace the stored copy', () async {
    await store.applyMessage(_message(id: 'm1', seq: 3, content: 'original'));
    await store.applyMessage(
      _message(id: 'm1', seq: 3, content: 'edited', editedAt: 2000),
    );

    final rows = await store.watchChannel('chan-1').first;
    expect(rows.single.content, 'edited');
    expect(rows.single.editedAt, 2000);
  });

  test('the cursor only ever moves forward', () async {
    await store.applyMessage(_message(id: 'm1', seq: 1));
    await store.applyMessage(_message(id: 'm3', seq: 3));
    expect(await _cursorOf(store, 'chan-1'), 3);

    // Backfilling an older message must not rewind the resume point.
    await store.applyMessage(_message(id: 'm2', seq: 2));
    expect(await _cursorOf(store, 'chan-1'), 3);
  });

  test('cursorFor reads a held channel, and is null for an unknown one',
      () async {
    expect(await store.cursorFor('chan-1'), 0);
    await store.applyMessage(_message(id: 'm1', seq: 4));
    expect(await store.cursorFor('chan-1'), 4);
    expect(await store.cursorFor('chan-2'), 0);
    expect(await store.cursorFor('nope'), isNull);
  });

  test('cursors are per channel', () async {
    await store.applyMessage(_message(id: 'a', channelId: 'chan-1', seq: 7));
    await store.applyMessage(_message(id: 'b', channelId: 'chan-2', seq: 2));

    expect(await _cursorOf(store, 'chan-1'), 7);
    expect(await _cursorOf(store, 'chan-2'), 2);

    final cursors = await store.allCursors();
    expect(cursors.map((c) => '${c.channelId}:${c.afterSeq}').toSet(),
        {'chan-1:7', 'chan-2:2'});
  });

  test('the server copy replaces the optimistic echo in place', () async {
    await store.addPending(
      id: 'local-1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'typed by the user',
    );
    var rows = await store.watchChannel('chan-1').first;
    expect(rows.single.pending, isTrue);
    expect(rows.single.seq, 0, reason: 'no server order yet');

    // The acknowledgement carries the same client-generated id, so it lands on
    // the same row rather than appearing as a duplicate.
    await store.applyMessage(
      _message(id: 'local-1', seq: 4, content: 'typed by the user'),
    );

    rows = await store.watchChannel('chan-1').first;
    expect(rows, hasLength(1), reason: 'no duplicate beside the echo');
    expect(rows.single.pending, isFalse);
    expect(rows.single.seq, 4);
  });

  test('a failed send is kept so the user does not lose it', () async {
    await store.addPending(
      id: 'local-1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'important',
    );
    await store.markFailed('local-1', reason: 'the server refused it');

    final rows = await store.watchChannel('chan-1').first;
    expect(rows.single.failed, isTrue);
    expect(rows.single.pending, isFalse);
    expect(rows.single.content, 'important');
    expect(rows.single.failureReason, 'the server refused it');

    await store.discard('local-1');
    expect(await store.watchChannel('chan-1').first, isEmpty);
  });

  test(
      'failedMessages answers only what is actually failed, across every '
      'channel', () async {
    await store.upsertChannels([
      const api.Channel(
          id: 'chan-2', name: 'other', kind: 'text', createdAt: 0),
    ]);
    await store.addPending(
      id: 'sending',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'still in flight',
    );
    await store.addPending(
      id: 'failed-1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'refused here',
    );
    await store.markFailed('failed-1', reason: 'nope');
    await store.addPending(
      id: 'failed-2',
      channelId: 'chan-2',
      authorId: 'user-1',
      content: 'refused there',
    );
    await store.markFailed('failed-2', reason: 'also nope');
    await store.applyMessage(_message(id: 'delivered', seq: 1));

    final failed = await store.failedMessages();
    expect(failed.map((m) => m.id).toSet(), {'failed-1', 'failed-2'});
  });

  test('the read marker only ever moves forward', () async {
    await store.setReadMarker('chan-1', 2);
    expect(await _lastReadSeqOf(store, 'chan-1'), 2);

    // A stale read receipt must not rewind the marker back below it.
    await store.setReadMarker('chan-1', 1);
    expect(await _lastReadSeqOf(store, 'chan-1'), 2);
  });

  test('reset clears the channel but keeps unsent and failed work', () async {
    await store.applyMessages([
      _message(id: 'm1', seq: 1),
      _message(id: 'm2', seq: 2),
    ]);
    await store.addPending(
      id: 'local-1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'still typing',
    );
    // markFailed also sets pending:false, so survival must key off failed too.
    await store.addPending(
      id: 'local-2',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'never sent',
    );
    await store.markFailed('local-2', reason: 'the server refused it');

    await store.resetChannel('chan-1');

    final rows = await store.watchChannel('chan-1').first;
    expect(rows.map((m) => m.id).toSet(), {'local-1', 'local-2'},
        reason: 'the unsent message and the failed one both survive');
    expect(await _cursorOf(store, 'chan-1'), 0,
        reason: 'refetch from the start');
  });

  test('removeChannel forgets the channel and only its own messages', () async {
    await store.applyMessages([
      _message(id: 'm1', seq: 1),
      _message(id: 'm2', channelId: 'chan-2', seq: 1),
    ]);

    await store.removeChannel('chan-1');

    expect(await store.watchChannels().first,
        isNot(contains(predicate((c) => (c as Channel).id == 'chan-1'))));
    expect(await store.watchChannel('chan-1').first, isEmpty);
    expect(await store.watchChannel('chan-2').first, hasLength(1),
        reason: 'a sibling channel is untouched');
  });

  test('clear leaves nothing at all for whoever signs in next', () async {
    // One database file for the whole app, so anything surviving a sign-out is
    // read by the next person; unlike resetChannel that includes pending sends.
    await store.applyMessages([
      _message(id: 'm1', seq: 1),
      _message(id: 'm2', channelId: 'chan-2', seq: 1),
    ]);
    await store.addPending(
      id: 'local-1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'never sent',
    );
    await store.setReadMarker('chan-1', 1);

    await store.clear();

    expect(await store.watchChannel('chan-1').first, isEmpty);
    expect(await store.watchChannel('chan-2').first, isEmpty,
        reason: 'every channel goes, not just the one on screen');
    expect(await store.watchChannels().first, isEmpty,
        reason: 'the channel list itself leaks which server this was');
  });

  test('out-of-order arrival still reads back in seq order', () async {
    await store.applyMessage(_message(id: 'm3', seq: 3, content: 'third'));
    await store.applyMessage(_message(id: 'm1', seq: 1, content: 'first'));
    await store.applyMessage(_message(id: 'm2', seq: 2, content: 'second'));

    final rows = await store.watchChannel('chan-1').first;
    expect(rows.map((m) => m.content), ['first', 'second', 'third']);
  });

  test('a channel refresh keeps the local cursor and read marker', () async {
    await store.applyMessage(_message(id: 'm1', seq: 9));
    await store.setReadMarker('chan-1', 5);

    // Re-fetching the channel list must not wipe local sync state.
    await store.upsertChannels([
      const api.Channel(
          id: 'chan-1', name: 'general-renamed', kind: 'text', createdAt: 1),
    ]);

    expect(await _cursorOf(store, 'chan-1'), 9);
    final channels = await store.watchChannels().first;
    final channel = channels.firstWhere((c) => c.id == 'chan-1');
    expect(channel.name, 'general-renamed');
    expect(channel.lastReadSeq, 5);
  });

  test('dmParticipantId round-trips and updates on a later upsert', () async {
    await store.upsertChannels([
      const api.Channel(
        id: 'dm-1',
        name: 'Alice',
        kind: 'dm',
        createdAt: 1,
        dmParticipantId: 'alice',
      ),
    ]);

    var channels = await store.watchChannels().first;
    expect(channels.firstWhere((c) => c.id == 'dm-1').dmParticipantId, 'alice');

    // A row cached before this column existed carries null until refreshed.
    await store.upsertChannels([
      const api.Channel(
          id: 'chan-1', name: 'general', kind: 'text', createdAt: 1),
    ]);
    channels = await store.watchChannels().first;
    expect(
        channels.firstWhere((c) => c.id == 'chan-1').dmParticipantId, isNull);
  });

  test(
      'replaceChannels prunes a channel the server no longer lists, '
      'keeping cursor and read marker for the rest', () async {
    await store.applyMessage(_message(id: 'm1', seq: 9));
    await store.applyMessages([_message(id: 'm2', channelId: 'chan-2')]);
    await store.setReadMarker('chan-1', 5);

    // Drops chan-2 (a revoked view) and adds a channel never seen before.
    await store.replaceChannels([
      const api.Channel(
          id: 'chan-1', name: 'general', kind: 'text', createdAt: 1),
      const api.Channel(
          id: 'chan-3', name: 'new-one', kind: 'text', createdAt: 3),
    ]);

    final channels = await store.watchChannels().first;
    expect(channels.map((c) => c.id), unorderedEquals(['chan-1', 'chan-3']));
    expect(await _cursorOf(store, 'chan-1'), 9,
        reason: 'a channel that stays keeps its cursor');
    expect(channels.firstWhere((c) => c.id == 'chan-1').lastReadSeq, 5,
        reason: 'and its read marker');
    expect(await store.watchChannel('chan-2').first, isEmpty,
        reason: 'the dropped channel loses its cached messages too, '
            'not just its row');
  });

  test('watchChannels excludes a thread, mirroring the server\'s own list',
      () async {
    await store.upsertChannels([
      const api.Channel(
        id: 'thread-1',
        name: 'Thread',
        kind: 'text',
        createdAt: 3,
        parentMessageId: 'm1',
      ),
    ]);

    final channels = await store.watchChannels().first;
    expect(channels.map((c) => c.id), unorderedEquals(['chan-1', 'chan-2']),
        reason: 'a thread is a hidden sub-channel, never a rail entry');
  });

  test('watchChannelRow finds a thread that watchChannels excludes', () async {
    await store.upsertChannels([
      const api.Channel(
        id: 'thread-1',
        name: 'Thread',
        kind: 'text',
        createdAt: 2,
        parentMessageId: 'm1',
      ),
    ]);

    final row = await store.watchChannelRow('thread-1').first;
    expect(row?.id, 'thread-1');
    expect(row?.parentMessageId, 'm1');
  });

  test(
      'replaceChannels spares a locally known thread the pruning an ordinary '
      'dropped channel gets', () async {
    await store.upsertChannels([
      const api.Channel(
          id: 'chan-1', name: 'general', kind: 'text', createdAt: 1),
      const api.Channel(
        id: 'thread-1',
        name: 'Thread',
        kind: 'text',
        createdAt: 2,
        parentMessageId: 'm1',
      ),
    ]);
    await store.applyMessages(
      [_message(id: 'tm1', channelId: 'thread-1', seq: 1)],
    );

    // A full refresh names only chan-1; GET /channels never lists a thread.
    await store.replaceChannels([
      const api.Channel(
          id: 'chan-1', name: 'general', kind: 'text', createdAt: 1),
    ]);

    final row = await store.watchChannelRow('thread-1').first;
    expect(row, isNotNull, reason: 'the thread row must survive the refresh');
    expect(await store.watchChannel('thread-1').first, isNotEmpty,
        reason: 'and its cached messages with it');
  });

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
