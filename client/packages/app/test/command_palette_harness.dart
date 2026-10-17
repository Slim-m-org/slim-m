// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the command palette suites: the fake API client, the
/// provider container it wires into, and the router/pump/keypress helpers
/// both suites drive the palette through.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. It
/// exists because `command_palette_test.dart` (opening the palette, browsing
/// and navigating from it) and `command_palette_search_test.dart` (the
/// palette's own message search) need the same session, the same fake HTTP
/// client shape, and the same way of opening and pumping the palette.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/widgets/command_palette_compact.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

api.Me me(int permissions) => api.Me(
  id: 'self',
  username: 'self',
  displayName: 'Self',
  createdAt: 0,
  permissions: permissions,
);

const tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.UserProfile profile(String id, String name) => api.UserProfile(
  id: id,
  username: name.toLowerCase(),
  displayName: name,
  createdAt: 0,
);

/// Everything but `/dms/*`, `/blocks` and the message search throws, matching
/// the rest of this test suite's convention of an otherwise-always-failing
/// client so an unexpected call surfaces immediately instead of returning
/// something plausible-looking.
///
/// The palette only ever calls `GET /search/messages` (its cross-channel
/// scope), never the per-channel `.../messages/search` route
/// `channelSearchProvider` uses; both are matched here so this fixture stays
/// useful if a future test drives the per-channel route through the same
/// client.
http.Client fakeClient({
  List<String> blocked = const [],
  List<Map<String, dynamic>> hits = const [],
  bool searchForbidden = false,
}) => MockClient((request) async {
  if (request.url.path == '/blocks') {
    return http.Response(jsonEncode(blocked), 200);
  }
  if (request.url.path == '/search/messages' ||
      request.url.path.endsWith('/messages/search')) {
    if (searchForbidden) {
      return http.Response(jsonEncode({'error': 'denied'}), 403);
    }
    return http.Response(jsonEncode(hits), 200);
  }
  if (request.method == 'POST' && request.url.path == '/dms/other') {
    return http.Response(
      jsonEncode({
        'channel_id': 'dm-1',
        'user': {
          'id': 'other',
          'username': 'ren',
          'display_name': 'Ren',
          'created_at': 0,
        },
        'unread': 0,
        'created_at': 0,
      }),
      200,
    );
  }
  throw StateError('unexpected request in this test: ${request.url}');
});

({ProviderContainer container, SlimmDatabase db}) setupPalette({
  int permissions = 0,
  List<String> blocked = const [],
  List<Map<String, dynamic>> hits = const [],
  bool searchForbidden = false,
  List<api.UserProfile>? members,
  List<Override> overrides = const [],
}) {
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: fakeClient(
            blocked: blocked,
            hits: hits,
            searchForbidden: searchForbidden,
          ),
        );
        ref.onDispose(client.close);
        return client;
      }),
      databaseProvider.overrideWith((ref) => db),
      ...overrides,
      meProvider.overrideWith((ref) async => me(permissions)),
      membersProvider.overrideWith(
        (ref) async => members ?? [profile('other', 'Ren')],
      ),
    ],
  );
  return (container: container, db: db);
}

/// See home_shell_test.dart for why unmounting and pumping past Drift's
/// stream-cache timer, before disposing, is required here.
Future<void> teardown(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

/// [initial] lets a test start inside a channel, so a message-jump result
/// can assert whether the jump had to navigate at all.
GoRouter testRouter({String initial = '/channels'}) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(
      path: '/channels',
      builder: (context, state) =>
          const HomeShell(child: Center(child: Text('conversation'))),
    ),
    GoRoute(
      path: Routes.channelPattern,
      builder: (context, state) =>
          const HomeShell(child: Center(child: Text('conversation'))),
    ),
    GoRoute(
      path: Routes.personalSettings,
      builder: (context, state) =>
          const Scaffold(body: Text('personal-settings-screen')),
    ),
    GoRoute(
      path: Routes.spaceSettings,
      builder: (context, state) =>
          const Scaffold(body: Text('space-settings-screen')),
    ),
  ],
);

Future<void> pump(
  WidgetTester tester,
  ProviderContainer container, {
  String initial = '/channels',
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: testRouter(initial: initial),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> pressCtrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// A channel or member name the palette shows can also be on screen behind
/// it (the rail, the member pane), so tests scope the search to the
/// palette's own floating card rather than matching either copy.
Finder inPalette(String text) =>
    find.descendant(of: find.byType(AppMenu), matching: find.text(text));

/// [inPalette]'s own equivalent for the compact shell, which never builds an
/// [AppMenu] at all.
Finder inCompactPalette(String text) => find.descendant(
  of: find.byType(CommandPaletteCompactShell),
  matching: find.text(text),
);
