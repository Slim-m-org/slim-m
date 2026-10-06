// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real [SyncController] over [SyncTestServer] and a [RestRouter], with a
/// seeded local store, for tests that need to see frames and catch-up rounds
/// interleave.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

import 'sync_harness.dart';

const syncRigTokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> rigMessage(String id, int seq, String content) => {
  'id': id,
  'channel_id': 'c1',
  'author_id': 'bob',
  'author_display_name': 'Bob',
  'seq': seq,
  'content': content,
  'created_at': 1000,
  'edited_at': null,
};

class SyncLiveRig {
  SyncLiveRig._(this.db, this.store, this.server, this.router, this.container);

  final SlimmDatabase db;
  final MessageStore store;
  final SyncTestServer server;
  final RestRouter router;
  final ProviderContainer container;

  SyncStatus get status => container.read(syncControllerProvider);

  /// Seeds channel `c1` with the given messages, then builds the controller.
  /// The caller registers `/sync` (and anything else) on [router] first via
  /// [configure], then calls [signIn].
  static Future<SyncLiveRig> build(
    void Function(RestRouter router) configure, {
    required List<Map<String, dynamic>> seeded,
    int? opCursor,
    MessageStore Function(SlimmDatabase db)? makeStore,
  }) async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = makeStore?.call(db) ?? MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    for (final m in seeded) {
      await store.applyMessage(api.Message.fromJson(m));
    }
    if (opCursor != null) await store.setOpCursor('c1', opCursor);

    final server = await SyncTestServer.start();
    addTearDown(server.close);
    final router = RestRouter()
      ..on(
        'GET',
        '/channels',
        (_) => jsonResponse([
          {'id': 'c1', 'name': 'general', 'kind': 'text', 'created_at': 0},
        ]),
      )
      ..on(
        'GET',
        '/channels/c1/read',
        (_) => jsonResponse({'last_read_seq': 0, 'unread': 0}),
      );
    configure(router);
    if (!_hasRoute(router, '/auth/ws-ticket')) {
      router.on(
        'POST',
        '/auth/ws-ticket',
        (_) => jsonResponse({'ticket': 'tix', 'expires_at': 0}),
      );
    }

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
      ],
    );
    addTearDown(container.dispose);
    return SyncLiveRig._(db, store, server, router, container);
  }

  static bool _hasRoute(RestRouter router, String path) =>
      router.hasRoute('POST', path);

  void signIn() {
    container.read(syncControllerProvider.notifier);
    container.read(sessionProvider).set(syncRigTokens);
  }

  Future<void> waitFor(bool Function() done, {int ms = 5000}) async {
    for (var i = 0; i < ms ~/ 25; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<Map<String, String>> contents() async => {
    for (final r in await db.select(db.messages).get()) r.id: r.content,
  };
}
