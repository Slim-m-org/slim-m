// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail has two separate settings entry points now, and each must reach
/// only its own screen: the Space menu (the chevron beside the Space name)
/// reaches Space settings, and the footer's settings control reaches
/// personal settings. Neither may land on the other's screen, and the Space
/// menu itself must not exist for a caller holding none of the four bits
/// that gate Space settings, matching `settings_space_section_test.dart`'s
/// gating of the screen it would otherwise open onto.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/widgets/command_palette_items.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Stands in for the real [SyncController], matching `channel_rail_test.dart`'s
/// own stub: it opens a websocket from its own constructor otherwise.
class _StubSyncController extends SyncController {
  _StubSyncController(super.ref) {
    state = SyncStatus.live;
  }

  @override
  Future<void> start() async {}
}

ProviderContainer _setup(int permissions) {
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith((ref) => _StubSyncController(ref)),
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
            return http.Response(
              '{}',
              404,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
}

/// A router carrying the rail's header and footer plus both settings routes,
/// each rendering distinguishable placeholder text so a test can tell which
/// one a tap actually reached.
GoRouter _router() => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(
      path: '/home',
      builder: (context, state) => const Scaffold(
        body: Column(children: [RailHeader(), Spacer(), RailUserFooter()]),
      ),
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
    "the footer's settings control reaches personal settings, never Space "
    'settings, even for a caller who could also reach Space settings',
    (tester) async {
      final container = _setup(Perm.manageServer);
      addTearDown(container.dispose);
      await _pump(tester, container);

      await tester.tap(find.bySemanticsLabel('Personal settings'));
      await tester.pumpAndSettle();

      expect(find.text('personal-settings-screen'), findsOneWidget);
      expect(find.text('space-settings-screen'), findsNothing);
    },
  );

  testWidgets(
    'the Space menu reaches Space settings, never personal settings, for a '
    'caller who can manage the Space',
    (tester) async {
      final container = _setup(Perm.manageServer);
      addTearDown(container.dispose);
      await _pump(tester, container);

      await tester.tap(find.bySemanticsLabel('Space menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Space settings'));
      await tester.pumpAndSettle();

      expect(find.text('space-settings-screen'), findsOneWidget);
      expect(find.text('personal-settings-screen'), findsNothing);
    },
  );

  testWidgets(
    'the command palette pushes settings over the app, so closing returns to '
    'where it was rather than stranding the user',
    (tester) async {
      final container = _setup(Perm.manageServer);
      addTearDown(container.dispose);

      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () {
                    final item = buildActionItems(
                      '',
                      Perm.manageServer,
                    ).firstWhere((i) => i.label == 'Open personal settings');
                    item.onSelect(context, ref);
                  },
                  child: const Text('home-shell'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: Routes.personalSettings,
            builder: (context, state) =>
                const Scaffold(body: Text('personal-settings-screen')),
          ),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: buildTheme(Brightness.light, AppTokens.light),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('home-shell'));
      await tester.pumpAndSettle();
      expect(find.text('personal-settings-screen'), findsOneWidget);

      // Pushed, not replaced: something is beneath to return to, so a back
      // navigation lands on the shell rather than exiting it. go would have
      // removed the shell and stranded the user here.
      final navigator = Navigator.of(
        tester.element(find.text('personal-settings-screen')),
      );
      expect(navigator.canPop(), isTrue);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('home-shell'), findsOneWidget);
      expect(find.text('personal-settings-screen'), findsNothing);
    },
  );

  testWidgets(
    'the Space menu opens for a member holding none of the four gating bits, '
    'without Space settings, so it never leads onto an empty screen',
    (tester) async {
      final container = _setup(0);
      addTearDown(container.dispose);
      await _pump(tester, container);

      await tester.tap(find.bySemanticsLabel('Space menu'));
      await tester.pumpAndSettle();

      expect(find.text('Saved messages'), findsOneWidget);
      expect(find.text('Space settings'), findsNothing);
      // Unaffected: the footer's control never leads to Space settings.
      expect(find.bySemanticsLabel('Personal settings'), findsOneWidget);
    },
  );
}
