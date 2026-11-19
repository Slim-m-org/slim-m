// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Catch-up swapping or dropping a channel's rows must leave scroll-back
/// contiguous: history the user paged in stays, or paging starts over.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';

import '../support/sync_model_server.dart';
import '../support/sync_model_world.dart';

Future<SyncModelWorld> _pagedBack({SyncModelServer? server}) async {
  final world = SyncModelWorld(server: server);
  await world.open();
  addTearDown(world.close);
  for (var i = 0; i < 120; i++) {
    world.server.send('v$i');
  }
  await _history(world).hydrate();
  _history(world).syncOldest((await world.heldSeqs()).first);
  await _history(world).loadOlder();
  expect((await world.heldSeqs()).first, lessThan(71));
  return world;
}

ChannelHistoryController _history(SyncModelWorld world) =>
    world.container.read(channelHistoryProvider('c1').notifier);

/// Scrolls back to the channel's start, as the transcript does: it reports its oldest row, then pages.
Future<void> _pageToStart(SyncModelWorld world) async {
  _history(world).syncOldest((await world.heldSeqs()).first);
  while (!world.container.read(channelHistoryProvider('c1')).atStart) {
    await _history(world).loadOlder();
  }
}

void main() {
  test('a first catch-up over held messages leaves history the user paged in, '
      'and paging stays contiguous', () async {
    final world = await _pagedBack();
    world.server.edit(world.server.messages.last, 'edited');
    final paged = await world.heldSeqs();

    await world.controller.reconcile();

    expect(await world.heldSeqs(), paged);
    await _pageToStart(world);
    expect(await world.heldSeqs(), [for (var seq = 1; seq <= 120; seq++) seq]);
    expect(await world.disagreement(), isNull);
  });
}
