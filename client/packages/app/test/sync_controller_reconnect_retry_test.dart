// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message left `failed` from before the socket went down must not sit
/// there forever waiting for the person to notice and tap Retry: the moment
/// `SyncController` reconnects, it is safe to replay unconditionally, since
/// the server's send route is idempotent by the message's own id. See
/// `retryFailedSends` in `providers/failed_send_retry.dart`.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';

import 'support/sync_harness.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _channelJson() => {
  'id': 'c1',
  'name': 'general',
  'kind': 'text',
  'created_at': 0,
};

void main() {
  testWidgets('a locally failed send retries automatically, once, the moment the '
      'socket reconnects', (tester) async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);

    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await store.addPending(
      id: 'failed-1',
      channelId: 'c1',
      authorId: 'bob',
      content: 'oops, sent while offline',
    );
    await store.markFailed('failed-1', reason: 'offline');

    // `runAsync` avoids the shutdown hang `SyncTestServer`'s own doc comment explains.
    final server = (await tester.runAsync(SyncTestServer.start))!;
    await tester.pump();

    var sendRequests = 0;
    final router = RestRouter()
      ..on('GET', '/channels', (_) => jsonResponse([_channelJson()]))
      ..on('GET', '/dms', (_) => jsonResponse(const <dynamic>[]))
      ..on(
        'GET',
        '/channels/c1/read',
        (_) => jsonResponse({'last_read_seq': 0, 'unread': 0}),
      )
      ..on(
        'POST',
        '/auth/ws-ticket',
        (_) => jsonResponse({'ticket': 'tix', 'expires_at': 0}),
      )
      ..on(
        'POST',
        '/sync',
        (_) => jsonResponse({
          'scopes': [
            {
              'channel_id': 'c1',
              'messages': <dynamic>[],
              'has_more': false,
              'reset': false,
            },
          ],
        }),
      )
      ..on('POST', '/channels/c1/messages', (request) async {
        sendRequests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({
          'id': body['id'],
          'channel_id': 'c1',
          'author_id': 'bob',
          'author_display_name': 'Bob',
          'seq': 1,
          'content': body['content'],
          'created_at': 0,
          'edited_at': null,
        });
      });

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore()),
        storeProvider.overrideWith((ref) async => store),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: server.baseUrl,
            session: ref.watch(sessionProvider),
            httpClient: router.build(),
          );
          ref.onDispose(client.close);
          return client;
        }),
        // Not overridden: this test needs the real controller to reach a live socket.
      ],
    );

    try {
      await tester.pumpWidget(const SizedBox.shrink());

      // The whole connect sequence, including the real socket handshake `_attach` performs, has to run in the real zone or it never completes - the same reason `SyncTestServer.start`/`.close` need `runAsync`.
      await tester.runAsync(() async {
        container.read(syncControllerProvider.notifier);
        container.read(sessionProvider).set(_tokens);
        for (var i = 0; i < 100; i++) {
          if (container.read(syncControllerProvider) == SyncStatus.live) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        // The reconnect retry fires straight off the live transition; give its own round trip a beat to finish and land in the store.
        for (var i = 0; i < 40; i++) {
          final row = await (store.db.select(
            store.db.messages,
          )..where((m) => m.id.equals('failed-1'))).getSingleOrNull();
          if (row != null && !row.failed && !row.pending) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });

      expect(
        container.read(syncControllerProvider),
        SyncStatus.live,
        reason: 'the retry hook only fires once the socket is back up',
      );
      expect(
        sendRequests,
        1,
        reason: 'the failed send must have been replayed exactly once',
      );

      final row = await (store.db.select(
        store.db.messages,
      )..where((m) => m.id.equals('failed-1'))).getSingle();
      expect(row.failed, isFalse);
      expect(row.pending, isFalse);
      expect(
        row.seq,
        1,
        reason:
            'the row must carry the server\'s own answer, not stay '
            'the local placeholder',
      );
    } finally {
      container.dispose();
      await tester.pump();
      // `runAsync` again, for the same reason `SyncTestServer.start` needed it above.
      await tester.runAsync(server.close);
    }
  });
}
