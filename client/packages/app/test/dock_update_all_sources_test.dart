// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Update all counts what the rows' badges count, community sources included,
/// installs each module from its own source, and names a module that lost the
/// approval to post messages (a new build drops it).
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
import 'package:slimm_app/src/screens/admin/dock_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

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

({MockClient client, List<String> installs, List<Map<String, dynamic>> bodies})
_world({
  required List<Map<String, dynamic>> communityRegistry,
  List<Map<String, dynamic>> officialRegistry = const [],
  required List<Map<String, dynamic>> installed,
  bool installKeepsPostMessages = false,
}) {
  final installs = <String>[];
  final bodies = <Map<String, dynamic>>[];
  final client = MockClient((request) async {
    final path = request.url.path;
    final source = request.url.queryParameters['source'];
    if (path == '/space/dock/sources') {
      return _json([
        {'id': 'official', 'repo': 'slim-m/modules', 'official': true},
        {'id': 'comm', 'repo': 'someone/mods', 'official': false},
      ]);
    }
    if (path == '/space/dock/modules') {
      return _json(source == 'comm' ? communityRegistry : officialRegistry);
    }
    if (path == '/space/dock/installed') return _json(installed);
    final match = RegExp(
      r'^/space/dock/modules/([^/]+)/install$',
    ).firstMatch(path);
    if (match != null && request.method == 'POST') {
      installs.add('${match.group(1)} source=$source');
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      final version = jsonDecode(request.body)['version'] as String;
      return _json({
        ..._installed(match.group(1)!, version),
        if (installKeepsPostMessages)
          'approved_host_capabilities': ['message.post'],
      });
    }
    throw StateError('unexpected request: ${request.method} ${request.url}');
  });
  return (client: client, installs: installs, bodies: bodies);
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
  testWidgets('a community module with an update badge is in Update all', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final world = _world(
      communityRegistry: [_entry('c', '2.0.0')],
      installed: [
        {..._installed('c', '1.0.0'), 'source_repo': 'someone/mods'},
      ],
    );
    await _open(tester, world.client);
    expect(find.text('UPDATE AVAILABLE'), findsOneWidget);
    expect(
      find.text('Update all'),
      findsOneWidget,
      reason: 'the row says an update exists, so the bar must offer it',
    );
    await tester.tap(find.text('Update all'));
    await tester.pumpAndSettle();
    expect(world.installs, ['c source=comm']);
  });

  testWidgets(
    'update all says when a module lost the approval to post messages',
    (tester) async {
      final world = _world(
        communityRegistry: [],
        officialRegistry: [_entry('a', '2.0.0')],
        installed: [
          {
            ..._installed('a', '1.0.0'),
            'approved_host_capabilities': ['message.post'],
          },
        ],
      );
      await _open(tester, world.client);
      await tester.tap(find.text('Update all'));
      await tester.pumpAndSettle();
      expect(
        find.text('Updated 1 of 1. a needs Post messages approved again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('an approval that is kept is not reported', (tester) async {
    final world = _world(
      communityRegistry: [],
      officialRegistry: [_entry('a', '2.0.0')],
      installed: [
        {
          ..._installed('a', '1.0.0'),
          'approved_host_capabilities': ['message.post'],
        },
      ],
      installKeepsPostMessages: true,
    );
    await _open(tester, world.client);
    await tester.tap(find.text('Update all'));
    await tester.pumpAndSettle();

    expect(world.installs, ['a source=null']);
    expect(find.textContaining('Post messages'), findsNothing);
  });

  testWidgets('official and community modules update together, each from '
      'its own source', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final world = _world(
      communityRegistry: [_entry('c', '2.0.0')],
      officialRegistry: [_entry('a', '2.0.0')],
      installed: [
        _installed('a', '1.0.0'),
        {..._installed('c', '1.0.0'), 'source_repo': 'someone/mods'},
      ],
    );
    await _open(tester, world.client);
    await tester.tap(find.text('Update all'));
    await tester.pumpAndSettle();

    expect(world.installs, ['a source=null', 'c source=comm']);
  });

  testWidgets('a module installed from another source is not this source\'s '
      'update', (tester) async {
    final world = _world(
      communityRegistry: [],
      officialRegistry: [_entry('x', '2.0.0')],
      installed: [
        {..._installed('x', '1.0.0'), 'source_repo': 'someone/mods'},
      ],
    );
    await _open(tester, world.client);

    expect(find.text('Update all'), findsNothing);
  });
}
