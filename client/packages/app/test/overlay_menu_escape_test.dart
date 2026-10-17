// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Three hand-rolled `OverlayPortal` popovers - the Space menu, the status
/// menu, and the personal space kebab - never adopted `ContextMenuFocus`'s
/// own `ContextMenuKeyboardScope`, the route `ContextMenuRegion` and both
/// canvas menus already use. Escape did nothing and focus never moved into
/// the opened menu on any of the three; a tap outside was the only way to
/// close them from the keyboard's own escape key.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/personal_space_menu.dart';
import 'package:slimm_app/src/features/members/widgets/presence_menu.dart';
import 'package:slimm_app/src/widgets/space_menu_button.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Client _api404() => MockClient((_) async => http.Response('{}', 404));

Future<void> _pumpSpaceMenu(WidgetTester tester) async {
  final container = ProviderContainer(
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
            if (request.url.path != '/me') return http.Response('{}', 404);
            return http.Response(
              '{"id":"self","username":"self","display_name":"Self",'
              '"created_at":0,"permissions":${Perm.manageChannels}}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (context, state) => const Scaffold(
          body: Align(alignment: Alignment.topRight, child: SpaceMenuButton()),
        ),
      ),
      GoRoute(
        path: Routes.spaceSettings,
        builder: (context, state) => const Scaffold(),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpPresenceMenu(WidgetTester tester) async {
  const me = api.Me(
    id: 'self',
    username: 'self',
    displayName: 'Self',
    createdAt: 0,
    permissions: -1,
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      meProvider.overrideWith((ref) async => me),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: _api404(),
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
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: Center(child: PresenceMenuButton())),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpPersonalSpaceKebab(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(const {});
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Center(
            child: PersonalSpaceKebab(visible: true, onFocusChange: (_) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Escape closes the Space menu', (tester) async {
    await _pumpSpaceMenu(tester);

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();
    expect(find.text('Space settings'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Space settings'), findsNothing);
  });

  testWidgets('Escape closes the status menu', (tester) async {
    await _pumpPresenceMenu(tester);

    await tester.tap(find.byType(PresenceMenuButton));
    await tester.pumpAndSettle();
    expect(find.text('Do not disturb'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Do not disturb'), findsNothing);
  });

  testWidgets('Escape closes the personal space kebab', (tester) async {
    await _pumpPersonalSpaceKebab(tester);

    await tester.tap(find.bySemanticsLabel('Personal space options'));
    await tester.pumpAndSettle();
    expect(find.text('Remove from list'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Remove from list'), findsNothing);
  });
}
