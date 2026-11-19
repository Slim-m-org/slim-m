// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What `sync_convergence_property_test.dart` found, each pinned as the
/// shortest run that shows it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show CursorAdvance, MessageStore;

import '../support/sync_model_server.dart';
import '../support/sync_model_world.dart';

Future<SyncModelWorld> _world() async {
  final world = SyncModelWorld();
  await world.open();
  addTearDown(world.close);
  return world;
}

/// A store whose next delete or edit write fails once, as a write that lost a lock race does.
class _FailsOnce extends MessageStore {
  _FailsOnce(super.db);

  bool failNext = false;

  void _maybeFail() {
    if (!failNext) return;
    failNext = false;
    throw StateError('database is locked');
  }

  @override
  Future<void> discard(String id) async {
    _maybeFail();
    return super.discard(id);
  }

  @override
  Future<void> applyEdited(api.Message message) async {
    _maybeFail();
    return super.applyEdited(message);
  }
}

void main() {
  group('a live op whose write fails', () {
    Future<(SyncModelWorld, _FailsOnce)> failing() async {
      final world = SyncModelWorld(makeStore: _FailsOnce.new);
      await world.open();
      addTearDown(world.close);
      await world.controller.reconcile();
      world.wire.add(world.server.send('hello'));
      await world.deliver();
      return (world, world.store as _FailsOnce);
    }

    test('is still owed: the delete lands on the next catch-up', () async {
      final (world, store) = await failing();
      world.wire.add(world.server.delete(world.server.messages.single));
      store.failNext = true;

      await expectLater(world.deliver(), throwsStateError);
      await world.controller.reconcile();

      expect(await world.contentOf('m1'), isNull);
      expect(await world.disagreement(), isNull);
    });

    test('is still owed: the edit lands on the next catch-up', () async {
      final (world, store) = await failing();
      world.wire.add(world.server.edit(world.server.messages.single, 'bye'));
      store.failNext = true;

      await expectLater(world.deliver(), throwsStateError);
      await world.controller.reconcile();

      expect(await world.contentOf('m1'), 'bye');
      expect(await world.disagreement(), isNull);
    });
  });

  group('a catch-up answer that was read before newer live edits landed', () {
    test('does not put the older text back', () async {
      final world = await _world();
      final server = world.server;
      await world.controller.reconcile();
      world.wire.add(server.send('zero'));
      await world.deliver();
      world.wire.add(server.edit(server.messages.single, 'one'));
      await world.startHeldCatchUp();
      world.wire.add(server.edit(server.messages.single, 'two'));
      await world.deliver();
      await world.deliver();
      expect(await world.contentOf('m1'), 'two');

      world.releaseAnswer();
      await pumpEventQueue(times: 20);

      expect(await world.contentOf('m1'), 'two');
      await world.settle();
      expect(await world.disagreement(), isNull);
    });
  });

  group(
    'a created frame for a message deleted before a reset read its page',
    () {
      Future<SyncModelWorld> afterReset({required bool reportsHead}) async {
        final world = SyncModelWorld(
          server: SyncModelServer(reportsHead: reportsHead),
        );
        await world.open();
        addTearDown(world.close);
        final server = world.server;
        world.wire.add(server.send('kept'));
        await world.deliver();
        final late = server.send('gone');
        server.delete(server.messages.last);
        await world.controller.reconcile();
        world.wire.add(late);
        return world;
      }

      test('is dropped: the cursor covers the deleted tail', () async {
        final world = await afterReset(reportsHead: true);
        expect(await world.store.cursorFor('c1'), 2);

        await world.deliver();

        expect(await world.contentOf('m2'), isNull);
        expect(await world.disagreement(), isNull);
      });

      test('still lands against a server that reports no head', () async {
        final world = await afterReset(reportsHead: false);
        expect(await world.store.cursorFor('c1'), 1);

        await world.deliver();

        expect(await world.contentOf('m2'), 'gone');
      });
    },
  );

  group('a catch-up answer landing in a tab the other tab has moved past', () {
    Future<(SyncModelWorld, SyncModelWorld)> tabs() async {
      final first = await _world();
      final second = SyncModelWorld(server: first.server, sharing: first);
      await second.open();
      addTearDown(second.close);
      return (first, second);
    }

    test('does not bring back a message the other tab deleted', () async {
      final (first, second) = await tabs();
      await first.controller.reconcile();
      first.wire.add(first.server.send('hello'));
      await second.startHeldCatchUp();
      await first.deliver();
      first.wire.add(first.server.delete(first.server.messages.single));
      await first.deliver();

      second.releaseAnswer();
      await pumpEventQueue(times: 20);

      expect(await first.contentOf('m1'), isNull);
    });
  });

  group('a live op for a channel with no op cursor', () {
    test('does not start the cursor past ops nobody applied', () async {
      final world = await _world();
      final server = world.server;
      world.wire.add(server.send('first'));
      await world.deliver();
      server.delete(server.messages.first);
      world.wire.add(server.send('second'));
      await world.deliver();
      world.wire.add(server.edit(server.messages.last, 'second, edited'));
      await world.deliver();

      await world.controller.reconcile();

      expect(await world.contentOf('m1'), isNull);
      expect(await world.disagreement(), isNull);
    });

    test('starts the cursor on the stream\'s first op', () async {
      final world = await _world();
      world.wire.add(world.server.send('first'));
      await world.deliver();
      world.wire.add(world.server.edit(world.server.messages.single, 'x'));
      await world.deliver();

      expect(await world.store.opCursorFor('c1'), 1);
      await world.controller.reconcile();
      expect(world.newestPageReads, 0);
      expect(await world.disagreement(), isNull);
    });
  });

  group(
    'a created frame the cursor already covers, for a message not held',
    () {
      test('does not bring back a message deleted meanwhile', () async {
        final world = await _world();
        final created = world.server.send('hello');
        world.server.delete(world.server.messages.single);
        world.wire.add(world.server.send('still here'));
        await world.controller.reconcile();

        world.wire.insert(0, created);
        await world.deliver();

        expect(await world.contentOf('m1'), isNull);
        expect(await world.disagreement(), isNull);
      });

      test('is not stored by a second tab that is behind the first', () async {
        final first = await _world();
        final second = SyncModelWorld(server: first.server, sharing: first);
        await second.open();
        addTearDown(second.close);
        await first.controller.reconcile();
        final frames = [
          first.server.send('hello'),
          first.server.delete(first.server.messages.single),
        ];

        for (final world in [first, second]) {
          world.wire.addAll(frames);
          await world.deliver();
          await world.deliver();
        }

        expect(await first.contentOf('m1'), isNull);
      });

      test(
        'still lands below a cursor that an answer to a send started',
        () async {
          final world = await _world();
          final earlier = [world.server.send('one'), world.server.send('two')];
          world.server.send('mine');
          await world.store.applyMessage(
            api.Message.fromJson(world.server.messages.last.toJson('c1')),
          );

          world.wire.addAll(earlier);
          await world.deliver();
          await world.deliver();

          expect(await world.contentOf('m1'), 'one');
          expect(await world.contentOf('m2'), 'two');
        },
      );

      test(
        'still lands when it is the sender\'s own pending message',
        () async {
          final world = await _world();
          await world.controller.reconcile();
          final created = world.server.send('hello');
          await world.store.addPending(
            id: 'm1',
            channelId: 'c1',
            authorId: 'alice',
            content: 'hello',
          );
          await world.store.advanceCursor('c1', [1], CursorAdvance.always);

          world.wire.add(created);
          await world.deliver();

          expect(await world.disagreement(), isNull);
          expect(await world.contentOf('m1'), 'hello');
        },
      );
    },
  );

  group('a channel first caught up while it already holds messages', () {
    test('drops a message deleted before its op cursor existed', () async {
      final world = await _world();
      world.wire.add(world.server.send('hello'));
      await world.deliver();
      world.server.delete(world.server.messages.single);

      await world.controller.reconcile();

      expect(await world.contentOf('m1'), isNull);
      expect(await world.disagreement(), isNull);
    });

    test('takes an edit made before its op cursor existed', () async {
      final world = await _world();
      world.wire.add(world.server.send('hello'));
      await world.deliver();
      world.server.edit(world.server.messages.single, 'hello there');

      await world.controller.reconcile();

      expect(await world.contentOf('m1'), 'hello there');
      expect(await world.disagreement(), isNull);
    });

    test(
      'stands at the newest message left once the newest was deleted',
      () async {
        final world = await _world();
        world.wire.addAll([world.server.send('one'), world.server.send('two')]);
        await world.deliver();
        await world.deliver();
        world.server.delete(world.server.messages.last);

        await world.controller.reconcile();

        expect(await world.contentOf('m2'), isNull);
        final row = (await world.store.channelRow('c1'))!;
        expect(row.liveSeq ?? row.cursor, 1);
      },
    );

    test('never leaves the channel empty while it refetches', () async {
      final world = await _world();
      world.wire.addAll([world.server.send('one'), world.server.send('two')]);
      await world.deliver();
      await world.deliver();
      world.server.edit(world.server.messages.first, 'one, edited');
      final counts = <int>[];
      final watching = world.store
          .watchChannel('c1')
          .listen((rows) => counts.add(rows.length));
      addTearDown(watching.cancel);
      await pumpEventQueue();

      await world.controller.reconcile();
      await pumpEventQueue();

      expect(await world.contentOf('m1'), 'one, edited');
      expect(counts, everyElement(2));
    });

    test('adopts the head without refetching when nothing is held', () async {
      final world = await _world();
      final first = world.server.send('hello');
      world.server.edit(world.server.messages.single, 'hello there');
      world.wire.add(first);

      await world.controller.reconcile();

      expect(await world.contentOf('m1'), 'hello there');
      expect(await world.store.opCursorFor('c1'), 1);
      expect(world.newestPageReads, 0);
    });
  });
}
