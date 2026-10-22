// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel deleted while the socket was down never produces a
/// `channel.deleted` frame for this client, so the reconnect itself has to
/// take it off the rail: `SyncController.start` refetches the channel list
/// and prunes whatever the server no longer lists.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';

import 'support/quick_reconnect.dart';
import 'support/sync_harness.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _channelJson(String id) => {
  'id': id,
  'name': id,
  'kind': 'text',
  'created_at': 0,
};

void main() {
  testWidgets('a channel deleted during a socket drop leaves the store on '
      'reconnect', (tester) async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);

    final server = (await tester.runAsync(SyncTestServer.start))!;
    await tester.pump();

    var listed = ['c1', 'doomed'];
    final router = RestRouter()
      ..on(
        'GET',
        '/channels',
        (_) => jsonResponse([for (final id in listed) _channelJson(id)]),
      )
      ..on(
        'GET',
        '/channels/c1/read',
        (_) => jsonResponse({'last_read_seq': 0, 'unread': 0}),
      )
      ..on(
        'GET',
        '/channels/doomed/read',
        (_) => jsonResponse({'last_read_seq': 0, 'unread': 0}),
      )
      ..on('POST', '/sync', (_) => jsonResponse({'scopes': <dynamic>[]}))
      ..on(
        'POST',
        '/auth/ws-ticket',
        (_) => jsonResponse({'ticket': 'tix', 'expires_at': 0}),
      );

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore()),
        storeProvider.overrideWith((ref) async => store),
        quickReconnect,
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: server.baseUrl,
            session: ref.watch(sessionProvider),
            httpClient: router.build(),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );

    Future<void> untilLive() async {
      for (var i = 0; i < 200; i++) {
        if (container.read(syncControllerProvider) == SyncStatus.live) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    try {
      await tester.pumpWidget(const SizedBox.shrink());

      await tester.runAsync(() async {
        container.read(syncControllerProvider.notifier);
        container.read(sessionProvider).set(_tokens);
        await untilLive();
      });
      expect(await store.hasChannel('doomed'), isTrue);

      listed = ['c1'];
      await tester.runAsync(() async {
        await server.dropSockets();
        for (var i = 0; i < 200; i++) {
          if (container.read(syncControllerProvider) != SyncStatus.live) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await untilLive();
      });

      expect(container.read(syncControllerProvider), SyncStatus.live);
      expect(await store.hasChannel('c1'), isTrue);
      expect(await store.hasChannel('doomed'), isFalse);
    } finally {
      container.dispose();
      await tester.pump();
      await tester.runAsync(server.close);
    }
  });
}
