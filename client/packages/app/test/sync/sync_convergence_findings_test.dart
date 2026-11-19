// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What `sync_convergence_property_test.dart` found, each pinned as the
/// shortest run that shows it.
library;

import 'package:flutter_test/flutter_test.dart';

import '../support/sync_model_world.dart';

Future<SyncModelWorld> _world() async {
  final world = SyncModelWorld();
  await world.open();
  addTearDown(world.close);
  return world;
}

void main() {
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
