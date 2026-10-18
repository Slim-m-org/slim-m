// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live op that skips past the channel's cursor is a gap, and a gap must
/// reconcile rather than apply.
///
/// `liveOpDecision` is unit-tested on its own (`message_ops_sync_test.dart`),
/// but every SyncController-level test fed it a null cursor, which it applies
/// unconditionally, so the numeric branch - cursor established, op jumps past
/// the next expected seq - was never driven through `_placeLiveOp`. This pins
/// what that branch does: the payload stays unapplied, the cursor stays where
/// it was (moving it past something never seen strands the channel for good),
/// and one catch-up round is scheduled.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/platform.dart';
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

/// A controller over an in-memory store whose API records every request
/// path, so a scheduled catch-up is observable as traffic.
({ProviderContainer container, MessageStore store, List<String> requests})
_harness() {
  final requests = <String>[];
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore()),
      storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final api = testApi((request) async {
          requests.add(request.url.path);
          return http.Response(jsonEncode({}), 200);
        }, session: SessionStore(tokens: _tokens));
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  return (container: container, store: store, requests: requests);
}

Future<SyncController> _seeded(
  ({ProviderContainer container, MessageStore store, List<String> requests})
  h, {
  required int cursor,
}) async {
  addTearDown(h.container.dispose);
  addTearDown(h.store.db.close);
  final controller = h.container.read(syncControllerProvider.notifier);
  await h.store.upsertChannels([Channel.fromJson(_channelJson(id: 'c1'))]);
  await h.store.addPending(
    id: 'm1',
    channelId: 'c1',
    authorId: 'user-1',
    content: 'still here',
  );
  await h.store.setOpCursor('c1', cursor);
  h.requests.clear();
  return controller;
}

Future<bool> _hasM1(MessageStore store) async {
  final rows = await store.watchChannel('c1').first;
  return rows.any((m) => m.id == 'm1');
}

void main() {
  test('an op past the next expected seq is held back, keeps the cursor, and '
      'schedules a catch-up', () async {
    final h = _harness();
    final controller = await _seeded(h, cursor: 1);

    await controller.applyServerEventForTest(
      const MessageDeleted(channelId: 'c1', messageId: 'm1', opSeq: 5),
    );
    await pumpEventQueue();

    expect(await _hasM1(h.store), isTrue, reason: 'a gapped op is not applied');
    expect(
      await h.store.opCursorFor('c1'),
      1,
      reason: 'the cursor never moves past something never seen',
    );
    expect(
      h.requests,
      isNotEmpty,
      reason: 'the gap must schedule one catch-up round',
    );
  });

  test('the next expected seq applies and advances the cursor', () async {
    final h = _harness();
    final controller = await _seeded(h, cursor: 1);

    await controller.applyServerEventForTest(
      const MessageDeleted(channelId: 'c1', messageId: 'm1', opSeq: 2),
    );
    await pumpEventQueue();

    expect(await _hasM1(h.store), isFalse);
    expect(await h.store.opCursorFor('c1'), 2);
    expect(h.requests, isEmpty, reason: 'an in-order op needs no catch-up');
  });

  test('an op at or below the cursor is ignored without a catch-up', () async {
    final h = _harness();
    final controller = await _seeded(h, cursor: 3);

    await controller.applyServerEventForTest(
      const MessageDeleted(channelId: 'c1', messageId: 'm1', opSeq: 2),
    );
    await pumpEventQueue();

    expect(
      await _hasM1(h.store),
      isTrue,
      reason: 'an already-seen op is a no-op',
    );
    expect(await h.store.opCursorFor('c1'), 3);
    expect(h.requests, isEmpty);
  });
}
