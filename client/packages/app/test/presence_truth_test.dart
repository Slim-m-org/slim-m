// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reproduces what the owner saw on a phone: the rail footer saying `unknown`
/// with a grey ring for someone who is online and using the app, and rings
/// that read "offline" for people nothing had been asked about yet.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Answers `/me`, and `/presence` the way the server does: at most 100 ids
/// per request, a 400 beyond that.
ProviderContainer _container({
  List<List<String>>? presenceRequests,
  String? storedVisibility,
}) => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    syncControllerProvider.overrideWith(StubSyncController.new),
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient((request) async {
          const json = {'content-type': 'application/json'};
          if (request.url.path == '/me') {
            return http.Response(
              jsonEncode({
                'id': 'self',
                'username': 'self',
                'display_name': 'Self',
                'created_at': 0,
                'permissions': 0,
                'presence_visibility': ?storedVisibility,
              }),
              200,
              headers: json,
            );
          }
          if (request.url.path == '/presence') {
            final ids = request.url.queryParameters['ids']!.split(',');
            presenceRequests?.add(ids);
            if (ids.length > 100) {
              return http.Response(
                '{"error":"too many ids"}',
                400,
                headers: json,
              );
            }
            return http.Response(
              jsonEncode([
                for (final id in ids) {'user_id': id, 'status': 'online'},
              ]),
              200,
              headers: json,
            );
          }
          return http.Response('{}', 404, headers: json);
        }),
      );
      ref.onDispose(client.close);
      return client;
    }),
  ],
);

Future<void> _pumpFooter(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Align(alignment: Alignment.bottomLeft, child: RailUserFooter()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a signed-in, connected user is never "unknown" to themself', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);

    expect(find.text('unknown'), findsNothing);
    expect(find.text('online'), findsOneWidget);
    final avatar = tester.widget<AppAvatar>(find.byType(AppAvatar));
    expect(avatar.status, AppPresence.online);
  });

  testWidgets('what the server says about the caller reaches the footer', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    container.read(presenceControllerProvider.notifier).state = {
      'self': api.PresenceState.dnd,
    };
    await _pumpFooter(tester, container);

    expect(find.text('do not disturb'), findsOneWidget);
    expect(
      tester.widget<AppAvatar>(find.byType(AppAvatar)).status,
      AppPresence.dnd,
    );
  });

  testWidgets('a member who chose to appear offline sees that on a fresh '
      'launch, from what the server stored', (tester) async {
    final container = _container(storedVisibility: 'hidden');
    addTearDown(container.dispose);
    container.read(presenceControllerProvider.notifier).state = {
      'self': api.PresenceState.online,
    };
    await _pumpFooter(tester, container);

    expect(find.text('appearing offline'), findsOneWidget);
    expect(find.text('online'), findsNothing);
    expect(
      tester.widget<AppAvatar>(find.byType(AppAvatar)).status,
      AppPresence.hidden,
    );
  });

  testWidgets('a choice made this session wins over the stored one', (
    tester,
  ) async {
    final container = _container(storedVisibility: 'hidden');
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);
    container.read(presenceVisibilityDisplayProvider.notifier).state =
        api.PresenceVisibility.online;
    await tester.pumpAndSettle();

    expect(find.text('online'), findsOneWidget);
    expect(find.text('appearing offline'), findsNothing);
  });

  test('a roster past the server batch ceiling is still all seeded', () async {
    final requests = <List<String>>[];
    final container = _container(presenceRequests: requests);
    addTearDown(container.dispose);

    final ids = [for (var i = 0; i < 230; i++) 'user-$i'];
    await container.read(presenceControllerProvider.notifier).refresh(ids);

    expect(
      container.read(presenceControllerProvider).length,
      230,
      reason: 'one request of 230 ids is a 400, and every ring stayed grey',
    );
    expect(requests.every((r) => r.length <= 100), isTrue);
  });
}
