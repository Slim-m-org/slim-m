// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A superseded sync run must not advance a channel's op cursor.
///
/// `_placeLiveOp` reads the cursor, decides whether the op can be placed, and
/// writes the cursor forward. Reading it is an await, and a sign-out or a
/// reconnect landing inside that await leaves the run holding a number from a
/// store the newer run has since moved past. Writing it back advances the
/// cursor over ops the live run never saw - and the function's own doc says
/// why that is the worst outcome available: a cursor moved past something
/// never seen is stranded permanently, where a stall only lasts a round.
///
/// Every other checkpoint in `SyncController.start` already rechecks
/// `isCurrent` after its awaits. This path read the cursor without it.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _channelJson({required String id}) => {
  'id': id,
  'name': 'general',
  'kind': 'text',
  'created_at': 0,
  'position': 0,
};

({ProviderContainer container, MessageStore store}) _harness() {
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore()),
      storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final api = testApi(
          (request) async => http.Response(jsonEncode({}), 200),
          session: SessionStore(tokens: _tokens),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  return (container: container, store: store);
}

void main() {
  test('a superseded run neither deletes nor moves the cursor', () async {
    final harness = _harness();
    addTearDown(harness.container.dispose);
    addTearDown(harness.store.db.close);
    final controller = harness.container.read(syncControllerProvider.notifier);

    await harness.store.upsertChannels([
      Channel.fromJson(_channelJson(id: 'c1')),
    ]);
    await harness.store.addPending(
      id: 'm1',
      channelId: 'c1',
      authorId: 'user-1',
      content: 'still here',
    );
    final cursorBefore = await harness.store.opCursorFor('c1');

    // Generation -1 can never be live: a run that has been superseded.
    await controller.applyServerEventForTest(
      const MessageDeleted(channelId: 'c1', messageId: 'm1', opSeq: 1),
      generation: -1,
    );

    expect(
      await harness.store.opCursorFor('c1'),
      cursorBefore,
      reason: 'advancing it here strands the channel for good',
    );
    final rows = await harness.store.watchChannel('c1').first;
    expect(
      rows.map((m) => m.id),
      contains('m1'),
      reason: 'a superseded run must not write into the store either',
    );
  });

  test('the live run still applies the same event', () async {
    final harness = _harness();
    addTearDown(harness.container.dispose);
    addTearDown(harness.store.db.close);
    final controller = harness.container.read(syncControllerProvider.notifier);

    await harness.store.upsertChannels([
      Channel.fromJson(_channelJson(id: 'c1')),
    ]);
    await harness.store.addPending(
      id: 'm1',
      channelId: 'c1',
      authorId: 'user-1',
      content: 'going away',
    );

    await controller.applyServerEventForTest(
      const MessageDeleted(channelId: 'c1', messageId: 'm1', opSeq: 1),
    );

    final rows = await harness.store.watchChannel('c1').first;
    expect(
      rows.map((m) => m.id),
      isNot(contains('m1')),
      reason: 'the guard must not cost the live path its delete',
    );
    expect(await harness.store.opCursorFor('c1'), 1);
  });
}
