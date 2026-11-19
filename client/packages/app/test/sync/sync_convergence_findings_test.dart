// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What `sync_convergence_property_test.dart` found, each pinned as the
/// shortest run that shows it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart' show CursorAdvance;

import '../support/sync_model_world.dart';

Future<SyncModelWorld> _world() async {
  final world = SyncModelWorld();
  await world.open();
  addTearDown(world.close);
  return world;
}

void main() {
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
