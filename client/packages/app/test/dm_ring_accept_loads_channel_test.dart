// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Accepting a ring for a DM this client never loaded.
///
/// A brand-new DM is not in the local store until the next channel refresh,
/// and the router answers an unknown channel with "This channel was not found,
/// or you do not have access to it". Accepting a ring must fetch the DM first.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

const _ring = IncomingDmCallRing(
  channelId: 'dm-new',
  ringId: 'ring-1',
  callerId: 'caller-1',
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<http.Response> _server(http.Request request) async {
  if (request.url.path == '/dms') {
    return _json([
      {
        'channel_id': 'dm-new',
        'user': {
          'id': 'caller-1',
          'username': 'alice',
          'display_name': 'Alice',
          'created_at': 0,
        },
        'unread': 0,
        'created_at': 1,
      },
    ]);
  }
  return http.Response('', 404);
}

void main() {
  testWidgets('accepting a ring loads a DM the store lacks before routing', (
    tester,
  ) async {
    final store = MessageStore(SlimmDatabase(NativeDatabase.memory()));
    addTearDown(store.db.close);
    final router = GoRouter(
      initialLocation: '/channels',
      routes: [
        GoRoute(path: '/channels', builder: (_, __) => const Placeholder()),
        GoRoute(
          path: Routes.channelPattern,
          builder: (_, __) => const Placeholder(),
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        routerProvider.overrideWithValue(router),
        storeProvider.overrideWith((ref) async => store),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: api.SessionStore(tokens: _tokens),
            httpClient: MockClient(_server),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    expect(await tester.runAsync(store.allChannels), isEmpty);
    await tester.runAsync(
      () => container.read(dmCallRingControllerProvider.notifier).accept(_ring),
    );
    await tester.pumpAndSettle();

    final channels = await tester.runAsync(store.allChannels);
    expect(
      channels!.map((c) => c.id),
      contains('dm-new'),
      reason: 'the DM must be fetched over REST',
    );
    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      Routes.channel('dm-new'),
    );
  });
}
