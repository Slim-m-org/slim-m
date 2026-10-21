// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Updating an installed module to the version the marketplace now offers.
///
/// Before this there was no update at all: the Dock row showed the registry's
/// version next to the word "Installed", which reads as agreement even when
/// the two disagree, and the only way to move a space forward was uninstall
/// and reinstall - which drops every permission grant and the enabled state
/// with it.
///
/// There is no separate route. Re-installing at the new version is the update:
/// `store/modules.rs` upserts the row, leaves `enabled` alone, and only drops
/// permission rows the new manifest stops declaring, so grants for surviving
/// keys come through. What is new here is all client-side - saying an update
/// exists, and not re-asking a question the space already answered.
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
import 'package:slimm_app/src/features/settings/screens/admin/dock_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _sha = List.filled(64, 'a').join();

/// What the marketplace currently offers.
Map<String, dynamic> _entry(String version) => {
  'id': 'game-of-life',
  'name': 'Game of Life',
  'version': version,
  'summary': 'Conway cellular automata.',
};

Map<String, dynamic> _manifest(String version, [Object? changelog]) => {
  ..._entry(version),
  'changelog': ?changelog,
  'author': 'slim-m',
  'artifact': {
    'kind': 'wasm',
    'path': 'modules/game-of-life/$version/module.wasm',
    'sha256': _sha,
  },
  'runtime': {
    'backend': 'wasm',
    'limits': {'memory_mb': 32, 'wall_ms': 1000, 'fuel': 100000000},
  },
  'permissions': [
    {
      'key': 'play',
      'name': 'Play cellular automata',
      'description': 'Seed and step.',
    },
  ],
  'capabilities': <String>[],
  'extension_points': [
    {'kind': 'app', 'name': 'Game of Life', 'permission': 'play'},
  ],
};

/// What this space has, which is where the two can disagree.
Map<String, dynamic> _installedRow(String version, {bool enabled = true}) => {
  'id': 'game-of-life',
  'name': 'Game of Life',
  'version': version,
  'artifact_sha256': _sha,
  'approved_capabilities': <String>[],
  'extension_points': <Map<String, dynamic>>[],
  'enabled': enabled,
  'installed_at': 1000,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Drives the Dock with the registry on [offered] and this space on
/// [installedVersion], recording what the update actually sends.
Future<List<String>> _pumpDock(
  WidgetTester tester, {
  required String offered,
  required String installedVersion,
  bool enabled = true,
  Object? changelog,
}) async {
  // The module screen is taller than the default 800x600 surface.
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final installs = <String>[];
  var version = installedVersion;
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/space/dock/modules') {
      return _json([_entry(offered)]);
    }
    if (path == '/space/dock/installed') {
      return _json([_installedRow(version, enabled: enabled)]);
    }
    if (path == '/space/dock/modules/game-of-life') {
      return _json(_manifest(offered, changelog));
    }
    if (path == '/space/dock/modules/game-of-life/install' &&
        request.method == 'POST') {
      installs.add(jsonDecode(request.body)['version'] as String);
      version = offered;
      return _json(_installedRow(offered, enabled: enabled));
    }
    if (path == '/roles') {
      return _json(<Map<String, dynamic>>[]);
    }
    if (path.contains('module-permissions')) {
      return _json(<Map<String, dynamic>>[]);
    }
    throw StateError('unexpected ${request.method} $path');
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
          initialLocation: Routes.adminDock,
          routes: [
            GoRoute(
              path: Routes.adminDock,
              builder: (context, state) => const DockScreen(),
            ),
            GoRoute(
              path: '${Routes.adminDock}/:moduleId',
              builder: (context, state) =>
                  DockModuleScreen(moduleId: state.pathParameters['moduleId']!),
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
  return installs;
}

const _notes = [
  {
    'version': '0.3.0',
    'changes': ['Faster steps'],
  },
  {
    'version': '0.2.0',
    'changes': ['Wraparound edges'],
  },
  {
    'version': '0.1.0',
    'changes': ['First release'],
  },
];

void main() {
  testWidgets("an outdated module lists only what it is missing", (
    tester,
  ) async {
    await _pumpDock(
      tester,
      offered: '0.3.0',
      installedVersion: '0.2.0',
      changelog: _notes,
    );
    await tester.tap(find.text('Game of Life'));
    await tester.pumpAndSettle();
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Faster steps'), findsOneWidget);
    expect(find.text('Wraparound edges'), findsNothing);
    expect(find.text('Update to v0.3.0'), findsOneWidget);
  });

  testWidgets('a current module shows no release notes', (tester) async {
    await _pumpDock(
      tester,
      offered: '0.3.0',
      installedVersion: '0.3.0',
      changelog: _notes,
    );
    await tester.tap(find.text('Game of Life'));
    await tester.pumpAndSettle();
    expect(find.text("What's new"), findsNothing);
  });

  testWidgets('an outdated module says so on its row', (tester) async {
    await _pumpDock(tester, offered: '0.3.0', installedVersion: '0.2.0');
    // AppBadge paints its label uppercased, whatever the variant.
    expect(find.text('UPDATE AVAILABLE'), findsOneWidget);
    expect(
      find.text('INSTALLED'),
      findsNothing,
      reason: '"Installed" beside a newer version reads as agreement',
    );
  });

  testWidgets('a current module says installed, not update', (tester) async {
    await _pumpDock(tester, offered: '0.3.0', installedVersion: '0.3.0');
    expect(find.text('INSTALLED'), findsOneWidget);
    expect(find.textContaining('UPDATE'), findsNothing);
  });

  testWidgets('updating sends the offered version and keeps the space put', (
    tester,
  ) async {
    final installs = await _pumpDock(
      tester,
      offered: '0.3.0',
      installedVersion: '0.2.0',
    );

    await tester.tap(find.text('Game of Life'));
    await tester.pumpAndSettle();
    expect(find.text('Update to v0.3.0'), findsOneWidget);
    expect(
      find.text('Install v0.3.0'),
      findsNothing,
      reason: 'an installed module is updated, never installed again',
    );

    await tester.tap(find.text('Update to v0.3.0'));
    await tester.pumpAndSettle();

    expect(installs, ['0.3.0']);
    expect(
      find.text('Who can use this'),
      findsNothing,
      reason:
          'the space already answered that; sending an update there reads as '
          'though the grants had been lost',
    );
    expect(
      find.text('Uninstall'),
      findsOneWidget,
      reason: 'it stays on the module screen',
    );
  });

  testWidgets('a disabled module can still be updated', (tester) async {
    final installs = await _pumpDock(
      tester,
      offered: '0.3.0',
      installedVersion: '0.2.0',
      enabled: false,
    );
    await tester.tap(find.text('Game of Life'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update to v0.3.0'));
    await tester.pumpAndSettle();
    expect(installs, ['0.3.0']);
  });
}
