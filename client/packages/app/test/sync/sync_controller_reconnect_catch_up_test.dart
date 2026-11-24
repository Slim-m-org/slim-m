// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message that arrived while the socket was down is stored by catch-up and
/// handed to alerts once the socket is live again; the first connect hands none.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' hide Message, Channel;
import 'package:slimm_platform/testing.dart';

import '../support/quick_reconnect.dart';
import '../support/sync_harness.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<void> _untilLive(ProviderContainer container, {bool live = true}) async {
  for (var i = 0; i < 200; i++) {
    if ((container.read(syncControllerProvider) == SyncStatus.live) == live) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('a reconnect hands its catch-up messages to alerts', (
    tester,
  ) async {
    var missed = false;
    final db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    await store.upsertChannels([
      const Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    final server = (await tester.runAsync(SyncTestServer.start))!;
    await tester.pump();
    final router = RestRouter()
      ..on(
        'GET',
        '/channels',
        (_) => jsonResponse([
          {'id': 'c1', 'name': 'general', 'kind': 'text', 'created_at': 0},
        ]),
      )
      ..on(
        'POST',
        '/sync',
        (_) => jsonResponse({
          'scopes': [
            {
              'channel_id': 'c1',
              'messages': [
                if (missed)
                  {
                    'id': 'm1',
                    'channel_id': 'c1',
                    'author_id': 'alice',
                    'author_display_name': 'Alice',
                    'seq': 1,
                    'content': 'while you were away',
                    'created_at': 0,
                    'edited_at': null,
                  },
              ],
              'has_more': false,
              'reset': false,
            },
          ],
        }),
      )
      ..on(
        'POST',
        '/auth/ws-ticket',
        (_) => jsonResponse({'ticket': 'tix', 'expires_at': 0}),
      );
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore()),
        storeProvider.overrideWith((ref) async => store),
        quickReconnect,
        apiProvider.overrideWith((ref) {
          final client = SlimmApi(
            baseUrl: server.baseUrl,
            session: ref.watch(sessionProvider),
            httpClient: router.build(),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    await tester.pumpWidget(const SizedBox.shrink());
    final batches = <List<Message>>[];

    await tester.runAsync(() async {
      container.read(syncControllerProvider.notifier);
      container.read(caughtUpMessagesProvider).listen(batches.add);
      container.read(sessionProvider).set(_tokens);
      await _untilLive(container);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(container.read(syncControllerProvider), SyncStatus.live);
    expect(batches, isEmpty);

    missed = true;
    await tester.runAsync(() async {
      await server.dropSockets();
      await _untilLive(container, live: false);
      await _untilLive(container);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    expect(batches.map((b) => b.map((m) => m.id).toList()), [
      ['m1'],
    ]);

    container.dispose();
    await tester.pump();
    await tester.runAsync(server.close);
    await db.close();
  });
}
