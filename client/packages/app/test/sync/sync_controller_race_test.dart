// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression test for SyncController.start() having no in-flight guard: a
/// sign-out landing while catch-up's network round trip is already running
/// must not let that round trip's answer write into the store the sign-out
/// just cleared. See sync_controller.dart's [SyncController._generation].
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('a sign-out landing mid-catch-up drops that round trip\'s answer '
      'instead of writing it into the store the sign-out just cleared', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);

    // A non-empty cursor already on the channel, so catch-up actually calls POST /sync.
    await store.upsertChannels([
      const Channel(id: 'chan-1', name: 'general', kind: 'text', createdAt: 1),
    ]);
    await store.applyMessage(
      const Message(
        id: 'm1',
        channelId: 'chan-1',
        authorId: 'user-1',
        authorDisplayName: 'User One',
        seq: 1,
        content: 'already here',
        createdAt: 1000,
        editedAt: null,
      ),
    );

    final syncGate = Completer<void>();

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        storeProvider.overrideWith((ref) async => store),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: ref.watch(serverUrlProvider),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.method == 'GET' && request.url.path == '/channels') {
                return _json([
                  {
                    'id': 'chan-1',
                    'name': 'general',
                    'kind': 'text',
                    'created_at': 1,
                  },
                ]);
              }
              if (request.method == 'GET' && request.url.path == '/dms') {
                return _json(<Object>[]);
              }
              if (request.url.path.endsWith('/read')) {
                return _json({'last_read_seq': 1, 'unread': 0});
              }
              if (request.method == 'POST' && request.url.path == '/sync') {
                // Held open until the test drives a sign-out through to a cleared store.
                await syncGate.future;
                return _json({
                  'scopes': [
                    {
                      'channel_id': 'chan-1',
                      'messages': [
                        {
                          'id': 'm2',
                          'channel_id': 'chan-1',
                          'author_id': 'someone-else',
                          'author_display_name': 'Someone Else',
                          'seq': 2,
                          'content': 'landed after sign-out',
                          'created_at': 2000,
                          'edited_at': null,
                        },
                      ],
                      'has_more': false,
                      'reset': false,
                    },
                  ],
                });
              }
              if (request.method == 'POST' &&
                  request.url.path == '/auth/logout') {
                return http.Response('', 204);
              }
              return http.Response('not found', 404);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(syncControllerProvider.notifier);
    container.read(sessionProvider).set(_tokens);

    // Let start() run up through issuing POST /sync, where it now blocks on syncGate.
    await pumpEventQueue();

    // Sign out while that request is still in flight.
    await container.read(apiProvider).logout();
    await pumpEventQueue();
    expect(
      await store.hasChannel('chan-1'),
      isFalse,
      reason:
          'sign-out must have cleared the store before the race is meaningful',
    );

    // Now let the stale catch-up's answer arrive.
    syncGate.complete();
    await pumpEventQueue();

    expect(
      await store.hasChannel('chan-1'),
      isFalse,
      reason:
          'a catch-up answer that lands after sign-out must not resurrect '
          'the channel it belonged to',
    );
    final leaked = await (store.db.select(
      store.db.messages,
    )..where((m) => m.id.equals('m2'))).getSingleOrNull();
    expect(
      leaked,
      isNull,
      reason:
          'the message the stale round trip carried must never reach the '
          'store at all, orphaned row or not',
    );
    expect(
      container.read(syncControllerProvider),
      SyncStatus.offline,
      reason:
          'the stale run must not declare itself live after being superseded',
    );
  });

  test('a channel listing that lands after sign-out is not written back into '
      'the store the sign-out just cleared', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const Channel(id: 'chan-1', name: 'general', kind: 'text', createdAt: 1),
    ]);

    final dmsGate = Completer<void>();

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        storeProvider.overrideWith((ref) async => store),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: ref.watch(serverUrlProvider),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.method == 'GET' && request.url.path == '/channels') {
                return _json([
                  {
                    'id': 'chan-1',
                    'name': 'general',
                    'kind': 'text',
                    'created_at': 1,
                  },
                ]);
              }
              if (request.method == 'GET' && request.url.path == '/dms') {
                // Held open so the sign-out lands inside the refresh, before its writes.
                await dmsGate.future;
                return _json(<Object>[]);
              }
              if (request.url.path.endsWith('/read')) {
                return _json({'last_read_seq': 1, 'unread': 0});
              }
              if (request.method == 'POST' && request.url.path == '/sync') {
                return _json({'scopes': <Object>[]});
              }
              if (request.method == 'POST' &&
                  request.url.path == '/auth/logout') {
                return http.Response('', 204);
              }
              return http.Response('not found', 404);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(syncControllerProvider.notifier);
    container.read(sessionProvider).set(_tokens);

    // Let start() reach GET /dms, where the refresh now blocks.
    await pumpEventQueue();

    await container.read(apiProvider).logout();
    await pumpEventQueue();
    expect(
      await store.hasChannel('chan-1'),
      isFalse,
      reason:
          'sign-out must have cleared the store before the race is meaningful',
    );

    dmsGate.complete();
    await pumpEventQueue();

    expect(
      await store.hasChannel('chan-1'),
      isFalse,
      reason:
          'the channel listing fetched for the account signing out must not '
          'be written into the store the next account will read',
    );
  });
}
