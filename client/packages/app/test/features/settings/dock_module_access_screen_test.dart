// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Installing a module offers to give somebody access to it.
///
/// A module's permissions are granted to nobody at install, and ADMINISTRATOR
/// does not bypass them, so an admin who installs one and walks away has a
/// module that appears nowhere - for them least of all. The screen the install
/// lands on, and the button that returns to it, is the step between installed
/// and usable.
///
/// It is a third routing level rather than a sheet: Space settings is already
/// a modal and the module screen is already a drill-down inside it, so a sheet
/// here put a second scrim over a screen that was dimming the shell.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_access_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _fakeSha256 = List.filled(64, 'a').join();

const _indexEntry = {
  'id': 'game-of-life',
  'name': 'Game of Life',
  'version': '0.2.0',
  'summary': 'Conway cellular automata on a channel-sized board.',
};

Map<String, dynamic> _manifest() => {
  ..._indexEntry,
  'author': 'slim-m',
  'artifact': {
    'kind': 'wasm',
    'path': 'modules/game-of-life/0.2.0/module.wasm',
    'sha256': _fakeSha256,
  },
  'runtime': {
    'backend': 'wasm',
    'limits': {'memory_mb': 32, 'wall_ms': 1000, 'fuel': 100000000},
  },
  'permissions': [
    {
      'key': 'play',
      'name': 'Play cellular automata',
      'description': 'Seed and step a board.',
    },
  ],
  'capabilities': <String>[],
  'extension_points': [
    {'kind': 'app', 'name': 'Game of Life', 'permission': 'play'},
  ],
};

/// Defaults to off, because a real install does: `installDockModule`'s own
/// doc says "installed off (disabled); a separate enableDockModule call turns
/// it on".
Map<String, dynamic> _installedRow({bool enabled = false}) => {
  'id': 'game-of-life',
  'name': 'Game of Life',
  'version': '0.2.0',
  'artifact_sha256': _fakeSha256,
  'approved_capabilities': <String>[],
  'extension_points': <Map<String, dynamic>>[],
  'enabled': enabled,
  'installed_at': 1000,
};

Map<String, dynamic> _role(String id, String name) => {
  'id': id,
  'name': name,
  'permissions': 0,
  'is_everyone': name == 'everyone',
  'mentionable': false,
  'created_at': 1000,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('installing offers the roles, and a grant reaches the server', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var installed = false;
    final granted = <String>[];
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/space/dock/modules') return _json([_indexEntry]);
      if (path == '/space/dock/modules/game-of-life') return _json(_manifest());
      if (path == '/space/dock/installed') {
        return _json(installed ? [_installedRow()] : <Object>[]);
      }
      if (path == '/space/dock/modules/game-of-life/install' &&
          request.method == 'POST') {
        installed = true;
        return _json(_installedRow());
      }
      if (path == '/roles') {
        return _json([
          _role('r-everyone', 'everyone'),
          _role('r-mods', 'mods'),
        ]);
      }
      if (path == '/roles/module-permissions') {
        return _json(<Map<String, dynamic>>[]);
      }
      if (path.endsWith('/module-permissions') && request.method == 'GET') {
        return _json(<Map<String, dynamic>>[]);
      }
      if (request.method == 'PUT' && path.contains('/module-permissions/')) {
        granted.add(path);
        return http.Response('', 204);
      }
      throw StateError('unexpected request: ${request.method} ${request.url}');
    });

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: GoRouter(
            initialLocation: '${Routes.adminDock}/game-of-life',
            routes: [
              GoRoute(
                path: '${Routes.adminDock}/:moduleId',
                builder: (context, state) => DockModuleScreen(
                  moduleId: state.pathParameters['moduleId']!,
                ),
              ),
              GoRoute(
                path: '${Routes.adminDock}/:moduleId/access',
                builder: (context, state) => DockModuleAccessScreen(
                  moduleId: state.pathParameters['moduleId']!,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Install v0.2.0'));
    await tester.pumpAndSettle();

    // Installed grants nothing, so the question is asked at once, by navigating.
    expect(find.text('Who can use this'), findsOneWidget);
    expect(
      find.byType(Dialog),
      findsNothing,
      reason: 'a sheet here scrims a settings modal that already scrims',
    );
    expect(find.textContaining('Play cellular automata'), findsWidgets);
    expect(find.text('everyone'), findsOneWidget);
    expect(find.text('mods'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Let mods use this module'));
    await tester.pumpAndSettle();
    expect(
      granted,
      contains('/roles/r-mods/module-permissions/game-of-life/play'),
      reason: 'the toggle must grant this module every key it declares',
    );

    // Back to the module, the way every other settings drill-down leaves.
    await tester.tap(find.bySemanticsLabel('Back to the module'));
    await tester.pumpAndSettle();
    expect(find.text('Who can use this'), findsNothing);

    // And it stays reachable afterwards, for a module installed long ago.
    await tester.tap(find.text('Choose who can use this'));
    await tester.pumpAndSettle();
    expect(find.text('Who can use this'), findsOneWidget);
  });

  testWidgets('granting a role turns the module on, because an install lands '
      'off and nothing else would', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var installed = false;
    var enabled = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/space/dock/modules') return _json([_indexEntry]);
      if (path == '/space/dock/modules/game-of-life') return _json(_manifest());
      if (path == '/space/dock/installed') {
        return _json(
          installed ? [_installedRow(enabled: enabled)] : <Object>[],
        );
      }
      if (path == '/space/dock/modules/game-of-life/install' &&
          request.method == 'POST') {
        installed = true;
        return _json(_installedRow(enabled: enabled));
      }
      if (path == '/space/dock/modules/game-of-life/enable' &&
          request.method == 'POST') {
        enabled = true;
        return _json(_installedRow(enabled: true));
      }
      if (path == '/roles') {
        return _json([_role('r-everyone', 'everyone')]);
      }
      if (path == '/roles/module-permissions') {
        return _json(<Map<String, dynamic>>[]);
      }
      if (path.endsWith('/module-permissions') && request.method == 'GET') {
        return _json(<Map<String, dynamic>>[]);
      }
      if (request.method == 'PUT' && path.contains('/module-permissions/')) {
        return http.Response('', 204);
      }
      throw StateError('unexpected request: ${request.method} ${request.url}');
    });

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: GoRouter(
            initialLocation: '${Routes.adminDock}/game-of-life',
            routes: [
              GoRoute(
                path: '${Routes.adminDock}/:moduleId',
                builder: (context, state) => DockModuleScreen(
                  moduleId: state.pathParameters['moduleId']!,
                ),
              ),
              GoRoute(
                path: '${Routes.adminDock}/:moduleId/access',
                builder: (context, state) => DockModuleAccessScreen(
                  moduleId: state.pathParameters['moduleId']!,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Install v0.2.0'));
    await tester.pumpAndSettle();
    expect(find.text('Who can use this'), findsOneWidget);
    expect(enabled, isFalse, reason: 'an install alone must not turn it on');

    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w is SettingsToggleRow &&
              w.semanticLabel == 'Let everyone use this module',
        ),
        matching: find.byType(AppToggle),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      enabled,
      isTrue,
      reason:
          'saying who may use it is the decision the install deliberately '
          'left open, so it is the moment to act on it',
    );
  });
}
