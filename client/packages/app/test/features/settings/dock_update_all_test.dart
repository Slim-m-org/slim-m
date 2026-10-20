// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Updating every outdated module in one press.
///
/// Before this, the only route to an update was opening each module in turn
/// and pressing its own button, which the row's "update" badge pointed at
/// without offering. The bar only appears when something is actually behind,
/// so the ordinary state of the screen is unchanged.
///
/// Drives the real client bindings through `SlimmApi` with a `MockClient`, the
/// shape `dock_screen_test.dart` established.
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
import 'package:slimm_app/src/features/settings/screens/admin/dock_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../dock_manifest_fixture.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _sha = List.filled(64, 'a').join();

Map<String, dynamic> _entry(String id, String version) => {
  'id': id,
  'name': id,
  'version': version,
  'summary': 'does something',
};

Map<String, dynamic> _installed(String id, String version) => {
  'id': id,
  'name': id,
  'version': version,
  'artifact_sha256': _sha,
  'approved_capabilities': <String>[],
  'extension_points': <Map<String, dynamic>>[],
  'enabled': true,
  'installed_at': 1000,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// The registry offers [registry]; this space has [installed].
/// [refuse] names the module ids whose install call answers 409.
({MockClient client, List<String> installs}) _world({
  required List<Map<String, dynamic>> registry,
  required List<Map<String, dynamic>> installed,
  Set<String> refuse = const {},
  Set<String> asksForAccess = const {},
}) {
  final installs = <String>[];
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/space/dock/modules') return _json(registry);
    if (path == '/space/dock/installed') return _json(installed);
    if (RegExp(r'^/space/dock/modules/([^/]+)$').firstMatch(path)
        case final manifest?) {
      return _json(
        dockManifestJson(
          manifest.group(1)!,
          '9.9.9',
          capabilities: asksForAccess.contains(manifest.group(1))
              ? ['message.post']
              : const [],
        ),
      );
    }
    final match = RegExp(
      r'^/space/dock/modules/([^/]+)/install$',
    ).firstMatch(path);
    if (match != null && request.method == 'POST') {
      final id = match.group(1)!;
      if (refuse.contains(id)) {
        return _json({
          'error': {'code': 'conflict', 'message': 'moved on'},
        }, 409);
      }
      installs.add(id);
      final version = jsonDecode(request.body)['version'] as String;
      return _json(_installed(id, version));
    }
    throw StateError('unexpected request: ${request.method} ${request.url}');
  });
  return (client: client, installs: installs);
}

ProviderContainer _containerFor(MockClient client) => ProviderContainer(
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

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
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
      ],
    ),
  ),
);

Future<ProviderContainer> _open(WidgetTester tester, MockClient client) async {
  final container = _containerFor(client);
  addTearDown(container.dispose);
  await tester.pumpWidget(_app(container));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('nothing offers an update when every module matches', (
    tester,
  ) async {
    final world = _world(
      registry: [_entry('a', '1.0.0'), _entry('b', '2.0.0')],
      installed: [_installed('a', '1.0.0'), _installed('b', '2.0.0')],
    );
    await _open(tester, world.client);
    expect(find.text('Update all'), findsNothing);
    expect(world.installs, isEmpty);
  });

  testWidgets('an uninstalled module is not an update', (tester) async {
    final world = _world(
      registry: [_entry('a', '1.0.0'), _entry('b', '9.9.9')],
      installed: [_installed('a', '1.0.0')],
    );
    await _open(tester, world.client);
    expect(
      find.text('Update all'),
      findsNothing,
      reason: 'b was never docked here, so there is nothing to bring forward',
    );
  });

  testWidgets('one press updates every outdated module', (tester) async {
    final world = _world(
      registry: [
        _entry('a', '2.0.0'),
        _entry('b', '2.0.0'),
        _entry('c', '1.0.0'),
      ],
      installed: [
        _installed('a', '1.0.0'),
        _installed('b', '1.5.0'),
        _installed('c', '1.0.0'),
      ],
    );
    await _open(tester, world.client);
    expect(find.text('2 modules have an update'), findsOneWidget);

    await tester.tap(find.text('Update all'));
    await tester.pumpAndSettle();

    expect(world.installs, [
      'a',
      'b',
    ], reason: 'only the two behind, and c was already current');
  });

  testWidgets('the count reads as one module when only one is behind', (
    tester,
  ) async {
    final world = _world(
      registry: [_entry('a', '2.0.0')],
      installed: [_installed('a', '1.0.0')],
    );
    await _open(tester, world.client);
    expect(find.text('1 module has an update'), findsOneWidget);
  });

  testWidgets('a refused module is named and the rest still go through', (
    tester,
  ) async {
    final world = _world(
      registry: [_entry('a', '2.0.0'), _entry('b', '2.0.0')],
      installed: [_installed('a', '1.0.0'), _installed('b', '1.0.0')],
      refuse: {'a'},
    );
    await _open(tester, world.client);
    await tester.tap(find.text('Update all'));
    await tester.pumpAndSettle();

    expect(world.installs, [
      'b',
    ], reason: 'one failure must not abandon the others');
    expect(
      find.textContaining('Updated 1 of 2'),
      findsOneWidget,
      reason: 'a partial result has to say so; silence would read as success',
    );
    expect(find.textContaining('a'), findsWidgets);
  });

  testWidgets('an update that asks for new access is left for review', (
    tester,
  ) async {
    final world = _world(
      registry: [_entry('a', '2.0.0'), _entry('b', '2.0.0')],
      installed: [_installed('a', '1.0.0'), _installed('b', '1.0.0')],
      asksForAccess: {'a'},
    );
    await _open(tester, world.client);
    await tester.tap(find.text('Update all'));
    await tester.pumpAndSettle();

    expect(world.installs, ['b'], reason: 'a needs the consent step first');
    expect(
      find.textContaining('a asks for new access. Open it to review.'),
      findsOneWidget,
    );
  });
}
