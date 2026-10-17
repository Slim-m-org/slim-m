// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Applying the message op stream, the last half of reconciliation.
///
/// Two properties carry the whole thing. An op's cursor moves only after the
/// op has been applied, so an interruption leaves the client asking for what
/// it has not yet seen. And a live op is applied only when it is exactly the
/// next one: a gap means something in between was never seen, and advancing
/// past it strands the cursor permanently, where declining to apply only
/// stalls until the next round.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_ops_sync.dart';
import 'package:slimm_app/src/providers/op_adjacency.dart';
import 'package:slimm_data/data.dart';

api.Message _message(String id, {int seq = 1, String content = 'original'}) =>
    api.Message(
      id: id,
      channelId: 'chan-1',
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: content,
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
      const api.Channel(
        id: 'chan-1',
        name: 'general',
        kind: 'text',
        createdAt: 1,
      ),
    ]);
  });

  tearDown(() => db.close());

  group('applyOps', () {
    test('an edit rewrites the cached copy and moves the cursor', () async {
      await store.applyMessage(_message('m1'));

      final outcome = await applyOps(store, 'chan-1', const [
        api.MessageEditOp(
          seq: 7,
          messageId: 'm1',
          createdAt: 1,
          content: 'revised',
          editedAt: 2000,
        ),
      ]);

      expect(outcome, OpsOutcome.applied);
      final rows = await store.watchChannel('chan-1').first;
      expect(rows.single.content, 'revised');
      expect(await store.opCursorFor('chan-1'), 7);
    });

    test('an edit op flagged forwarded_removed clears the snapshot, even '
        'with its content collapsed', () async {
      await store.applyMessage(
        const api.Message(
          id: 'm1',
          channelId: 'chan-1',
          authorId: 'user-1',
          authorDisplayName: 'User One',
          seq: 1,
          content: 'my note',
          createdAt: 1000,
          editedAt: null,
          forwarded: api.ForwardedMessage(
            messageId: 'o',
            channelId: 'chan-1',
            authorId: 'user-2',
            authorDisplayName: 'Alice',
            authorAvatarUpdatedAt: null,
            createdAt: 1,
            content: 'the original',
          ),
        ),
      );

      await applyOps(store, 'chan-1', const [
        api.MessageEditOp(
          seq: 9,
          messageId: 'm1',
          createdAt: 1,
          content: null,
          editedAt: null,
          forwardedRemoved: true,
        ),
      ]);

      final row = (await store.watchChannel('chan-1').first).single;
      expect(row.content, 'my note');
      expect(row.forwarded!.removed, isTrue);
      expect(row.forwarded!.content, '');
    });

    test('a delete removes the cached copy', () async {
      await store.applyMessage(_message('m1'));

      await applyOps(store, 'chan-1', const [
        api.MessageDeleteOp(seq: 8, messageId: 'm1', createdAt: 1),
      ]);

      expect(await store.watchChannel('chan-1').first, isEmpty);
      expect(await store.opCursorFor('chan-1'), 8);
    });

    test('an edit with no content still advances the cursor', () async {
      // Skipping the seq leaves a hole the adjacency test can never close.
      await store.applyMessage(_message('m1'));

      await applyOps(store, 'chan-1', const [
        api.MessageEditOp(
          seq: 3,
          messageId: 'm1',
          createdAt: 1,
          content: null,
          editedAt: null,
        ),
      ]);

      final rows = await store.watchChannel('chan-1').first;
      expect(rows.single.content, 'original', reason: 'nothing to apply');
      expect(await store.opCursorFor('chan-1'), 3);
    });

    test('an unknown kind asks for a reset and stops before it', () async {
      // Skipping advances past a change never made locally.
      await store.applyMessage(_message('m1'));

      final outcome = await applyOps(store, 'chan-1', const [
        api.MessageDeleteOp(seq: 1, messageId: 'm1', createdAt: 1),
        api.MessageUnknownOp(seq: 2, messageId: 'm2', createdAt: 1),
        api.MessageDeleteOp(seq: 3, messageId: 'm3', createdAt: 1),
      ]);

      expect(outcome, OpsOutcome.needsReset);
      expect(
        await store.opCursorFor('chan-1'),
        1,
        reason: 'the cursor stops at the last op actually understood',
      );
    });

    test('ops apply in order and the cursor ends at the last', () async {
      await store.applyMessage(_message('m1'));
      await store.applyMessage(_message('m2', seq: 2));

      await applyOps(store, 'chan-1', const [
        api.MessageEditOp(
          seq: 1,
          messageId: 'm1',
          createdAt: 1,
          content: 'first edit',
          editedAt: 1,
        ),
        api.MessageDeleteOp(seq: 2, messageId: 'm2', createdAt: 2),
        api.MessageEditOp(
          seq: 3,
          messageId: 'm1',
          createdAt: 3,
          content: 'second edit',
          editedAt: 3,
        ),
      ]);

      final rows = await store.watchChannel('chan-1').first;
      expect(rows.single.id, 'm1');
      expect(rows.single.content, 'second edit');
      expect(await store.opCursorFor('chan-1'), 3);
    });
  });

  group('liveOpDecision', () {
    test('exactly the next op is applied', () {
      expect(liveOpDecision(6, 5), LiveOpOutcome.applied);
    });

    test('one already seen is ignored', () {
      expect(liveOpDecision(5, 5), LiveOpOutcome.ignored);
      expect(liveOpDecision(3, 5), LiveOpOutcome.ignored);
    });

    test('a gap asks for a reconcile rather than applying', () {
      // Delivery order is best-effort, so two ahead means one was missed.
      expect(liveOpDecision(8, 5), LiveOpOutcome.needsReconcile);
    });

    test('an old server with no op seq applies the frame as before', () {
      expect(liveOpDecision(null, 5), LiveOpOutcome.applied);
    });

    test('a client holding no cursor applies the frame as before', () {
      // Nothing to compare against until catch-up adopts a head.
      expect(liveOpDecision(6, null), LiveOpOutcome.applied);
    });
  });
}
