// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The block list and the channel overrides are fetched when their controller
/// is built. A failed first fetch used to leave them empty until the app
/// restarted, and a change made elsewhere while the socket was down never
/// arrived. The sync controller now refetches them when it goes live.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

import 'support/sync_harness.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A sync controller over a real socket server, with `GET /blocks` and the
/// overrides route answering from [blocks] and [overrides], failing the first
/// [failFirst] requests to each.
class _Rig {
  _Rig(this.tester, {this.failFirst = 0});

  final WidgetTester tester;
  final int failFirst;
  List<String> blocks = ['pest'];
  List<Map<String, String>> overrides = [
    {'channel_id': 'c1', 'preference': 'nothing'},
  ];
  int blockHits = 0;
  int overrideHits = 0;

  late final SlimmDatabase db;
  late final SyncTestServer server;
  late final ProviderContainer container;

  Future<void> start() async {
    db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    server = (await tester.runAsync(SyncTestServer.start))!;
    await tester.pump();
    final router = RestRouter()
      ..on('GET', '/blocks', (_) {
        if (++blockHits <= failFirst) return http.Response('boom', 500);
        return jsonResponse(blocks);
      })
      ..on('GET', '/notification-preferences/channels', (_) {
        if (++overrideHits <= failFirst) return http.Response('boom', 500);
        return jsonResponse(overrides);
      })
      ..on('GET', '/channels', (_) => jsonResponse(<dynamic>[]))
      ..on('POST', '/sync', (_) => jsonResponse({'scopes': <dynamic>[]}))
      ..on(
        'POST',
        '/auth/ws-ticket',
        (_) => jsonResponse({'ticket': 'tix', 'expires_at': 0}),
      );
    container = ProviderContainer(
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
    await tester.pumpWidget(const SizedBox.shrink());
  }

  Future<void> untilLive() async {
    for (var i = 0; i < 200; i++) {
      if (container.read(syncControllerProvider) == SyncStatus.live) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> signInAndConnect() => tester.runAsync(() async {
    container.read(blocksProvider);
    container.read(channelNotificationOverridesProvider);
    container.read(syncControllerProvider.notifier);
    container.read(sessionProvider).set(_tokens);
    await untilLive();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  Future<void> dropAndReconnect() => tester.runAsync(() async {
    await server.dropSockets();
    for (var i = 0; i < 200; i++) {
      if (container.read(syncControllerProvider) != SyncStatus.live) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await untilLive();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  Future<void> close() async {
    container.dispose();
    await tester.pump();
    await tester.runAsync(server.close);
    await db.close();
  }
}

void main() {
  testWidgets(
    'a failed first fetch is retried when the socket first goes live',
    (tester) async {
      final rig = _Rig(tester, failFirst: 1);
      await rig.start();
      try {
        await rig.signInAndConnect();

        expect(rig.blockHits, 2);
        expect(rig.container.read(blocksProvider).error, isNull);
        expect(rig.container.read(blocksProvider).ids, {'pest'});
        expect(rig.overrideHits, 2);
        expect(
          rig.container
              .read(channelNotificationOverridesProvider)
              .isMuted('c1'),
          isTrue,
        );
      } finally {
        await rig.close();
      }
    },
  );

  testWidgets(
    'a first fetch that worked is not repeated at the first connect',
    (tester) async {
      final rig = _Rig(tester);
      await rig.start();
      try {
        await rig.signInAndConnect();

        expect(rig.blockHits, 1);
        expect(rig.overrideHits, 1);
      } finally {
        await rig.close();
      }
    },
  );

  testWidgets('a reconnect refetches both lists', (tester) async {
    final rig = _Rig(tester);
    await rig.start();
    try {
      await rig.signInAndConnect();
      rig.blocks = ['pest', 'troll'];
      rig.overrides = [
        {'channel_id': 'c2', 'preference': 'mentions'},
      ];

      await rig.dropAndReconnect();

      expect(rig.container.read(syncControllerProvider), SyncStatus.live);
      expect(rig.blockHits, 2);
      expect(rig.container.read(blocksProvider).ids, {'pest', 'troll'});
      expect(rig.overrideHits, 2);
      final overrides = rig.container.read(
        channelNotificationOverridesProvider,
      );
      expect(overrides.isMuted('c1'), isFalse);
      expect(overrides.overrideFor('c2'), api.NotificationPreference.mentions);
    } finally {
      await rig.close();
    }
  });
}
