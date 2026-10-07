// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the Space menu's channel-creation items (backlog item 55): the
/// rail used to float a bare "+" over the uncategorised section with no
/// header explaining it, and creation moved here instead, gated on
/// `MANAGE_CHANNELS` specifically rather than the broader set of bits that
/// merely make the menu itself reachable.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/space_menu_button.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_app/src/action_labels.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// [permissions] backs `GET /me`; [handler] answers anything else (channel
/// creation, most tests never need it).
ProviderContainer _setup(
  int permissions, {
  http.Response Function(http.Request)? handler,
}) {
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async {
        final db = SlimmDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return MessageStore(db);
      }),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/me') {
              return http.Response(
                jsonEncode({
                  'id': 'self',
                  'username': 'self',
                  'display_name': 'Self',
                  'created_at': 0,
                  'permissions': permissions,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            // The menu now watches the per-channel overrides, which the rail loads on mount.
            if (request.url.path == '/notification-preferences/channels') {
              return http.Response('[]', 200);
            }
            return (handler ?? (_) => http.Response('{}', 404))(request);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
}

GoRouter _router() => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(
      path: '/home',
      // Right-aligned, where RailHeader actually places this button: the follower menu needs the room.
      builder: (context, state) => const Scaffold(
        body: Align(alignment: Alignment.topRight, child: SpaceMenuButton()),
      ),
    ),
    GoRoute(
      path: Routes.spaceSettings,
      builder: (context, state) =>
          const Scaffold(body: Text('space-settings-screen')),
    ),
    GoRoute(
      path: Routes.channelPattern,
      builder: (context, state) =>
          Scaffold(body: Text('channel:${state.pathParameters['channelId']}')),
    ),
  ],
);

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: _router(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a caller with MANAGE_CHANNELS sees Create channel and Create category, '
    'alongside Space settings',
    (tester) async {
      final container = _setup(Perm.manageChannels);
      addTearDown(container.dispose);
      await _pump(tester, container);

      await tester.tap(find.bySemanticsLabel('Space menu'));
      await tester.pumpAndSettle();

      expect(find.text(ActionLabels.createChannel), findsOneWidget);
      expect(find.text(ActionLabels.createCategory), findsOneWidget);
      expect(find.text('Space settings'), findsOneWidget);
    },
  );

  testWidgets('a caller who can reach the menu on a different bit, without '
      'MANAGE_CHANNELS, sees Space settings but neither create item - '
      'offering one would just 403', (tester) async {
    final container = _setup(Perm.manageMessages);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();

    expect(find.text('Space settings'), findsOneWidget);
    expect(find.text(ActionLabels.createChannel), findsNothing);
    expect(find.text(ActionLabels.createCategory), findsNothing);
  });

  testWidgets('Create channel opens the create sheet, which posts the name and '
      'kind and lands on the new channel', (tester) async {
    final requests = <http.Request>[];
    final container = _setup(
      Perm.manageChannels,
      handler: (request) {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'id': 'new-1',
            'name': 'roadmap',
            'kind': 'text',
            'topic': null,
            'created_at': 1,
          }),
          200,
        );
      },
    );
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ActionLabels.createChannel));
    await tester.pumpAndSettle();
    expect(find.text('Create a channel'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'roadmap');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Create channel'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/channels');
    expect(
      jsonDecode(requests.single.body),
      allOf(
        containsPair('name', 'roadmap'),
        containsPair('kind', 'text'),
        containsPair('id', isA<String>()),
      ),
    );
    expect(find.text('channel:new-1'), findsOneWidget);
  });

  testWidgets(
    'Create category opens the create sheet directly, which posts the name',
    (tester) async {
      final requests = <http.Request>[];
      final container = _setup(
        Perm.manageChannels,
        handler: (request) {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'id': 'cat-1',
              'name': 'dev',
              'position': 0,
              'created_at': 1,
            }),
            200,
          );
        },
      );
      addTearDown(container.dispose);
      await _pump(tester, container);

      await tester.tap(find.bySemanticsLabel('Space menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(ActionLabels.createCategory));
      await tester.pumpAndSettle();
      expect(find.text('Create a category'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'dev');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppButton, 'Create category'));
      await tester.pumpAndSettle();

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/categories');
      expect(
        jsonDecode(requests.single.body),
        allOf(containsPair('name', 'dev'), containsPair('id', isA<String>())),
      );
    },
  );
}
