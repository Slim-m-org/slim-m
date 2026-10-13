// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock's community sources (decision 0046): a section per source with
/// its own label, a broken source failing alone, an id another source owns
/// shown as taken, and adding and removing a source.
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
import 'package:slimm_app/src/screens/admin/dock_module_screen.dart';
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

Map<String, dynamic> _entry(String id, {bool shadowed = false}) => {
  'id': id,
  'name': 'Module $id',
  'version': '0.1.0',
  'summary': 'Summary of $id.',
  'shadowed': shadowed,
};

Map<String, dynamic> _manifest(String id) => {
  ..._entry(id),
  'artifact': {'kind': 'wasm', 'path': 'm/$id.wasm', 'sha256': _sha},
  'runtime': {
    'backend': 'wasm',
    'limits': {'memory_mb': 64, 'wall_ms': 2000, 'fuel': 1000},
  },
  'permissions': <Map<String, dynamic>>[],
  'capabilities': ['command.register'],
  'extension_points': <Map<String, dynamic>>[],
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

const _official = {'id': 'official', 'repo': 'nc/addons', 'official': true};
const _acme = {'id': 's1', 'repo': 'acme/mods', 'official': false};
const _broken = {'id': 's2', 'repo': 'bad/repo', 'official': false};

class _Upstream {
  _Upstream({this.sources = const [_official, _acme]});

  List<Map<String, dynamic>> sources;
  final requests = <String>[];
  final bodies = <String, Object?>{};
  http.Response? addResponse;

  Future<http.Response> handle(http.Request r) async {
    final key =
        '${r.method} ${r.url.path}'
        '${r.url.hasQuery ? '?${r.url.query}' : ''}';
    requests.add(key);
    if (r.body.isNotEmpty) bodies[key] = jsonDecode(r.body);
    switch (key) {
      case 'GET /space/dock/sources':
        return _json(sources);
      case 'GET /space/dock/installed':
        return _json([]);
      case 'GET /space/dock/modules':
        return _json([_entry('official-mod')]);
      case 'GET /space/dock/modules?source=s1':
        return _json([_entry('extra'), _entry('taken', shadowed: true)]);
      case 'GET /space/dock/modules?source=s2':
        return _json({'error': 'bad index'}, 502);
      case 'GET /space/dock/modules/extra?source=s1':
        return _json(_manifest('extra'));
      case 'POST /space/dock/sources':
        return addResponse ?? _json(_acme, 201);
      case 'DELETE /space/dock/sources/s1':
        return http.Response('', 204);
    }
    return _json({'error': 'unexpected $key'}, 404);
  }
}

ProviderContainer _container(_Upstream upstream) {
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(upstream.handle),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    theme: buildTheme(Brightness.light, AppTokens.light),
    routerConfig: GoRouter(
      initialLocation: Routes.adminDock,
      routes: [
        GoRoute(
          path: Routes.adminDock,
          builder: (context, state) => const DockScreen(),
        ),
        GoRoute(
          path: '${Routes.adminDock}/:moduleId',
          builder: (context, state) => DockModuleScreen(
            moduleId: state.pathParameters['moduleId']!,
            source: state.uri.queryParameters['source'],
          ),
        ),
      ],
    ),
  ),
);

Future<_Upstream> _pump(WidgetTester tester, {_Upstream? upstream}) async {
  final u = upstream ?? _Upstream();
  final container = _container(u);
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(container));
  await tester.pumpAndSettle();
  return u;
}

Finder _badge(String label) =>
    find.byWidgetPredicate((w) => w is AppBadge && w.label == label);

void main() {
  testWidgets(
    'official and community modules sit in separately labelled sections',
    (tester) async {
      await _pump(tester);
      expect(find.text('Official modules'), findsOneWidget);
      expect(find.text('Module official-mod'), findsOneWidget);
      expect(find.text('Community source: acme/mods'), findsOneWidget);
      expect(find.text('Module extra'), findsOneWidget);
    },
  );

  testWidgets(
    'an id another source owns is shown as taken and cannot be opened',
    (tester) async {
      await _pump(tester);
      expect(_badge('Id taken'), findsOneWidget);
      await tester.tap(find.text('Module taken'));
      await tester.pumpAndSettle();
      expect(find.byType(DockScreen), findsOneWidget);
      expect(find.byType(DockModuleScreen), findsNothing);
    },
  );

  testWidgets('modules in one source card are told apart by a divider', (
    tester,
  ) async {
    await _pump(tester);
    final first = tester.getRect(find.text('Module extra'));
    final second = tester.getRect(find.text('Module taken'));
    final between = find
        .byWidgetPredicate((w) => w is Divider)
        .evaluate()
        .where((e) {
          final y = tester
              .getRect(find.byElementPredicate((x) => x == e))
              .center
              .dy;
          return y > first.bottom && y < second.top;
        });
    expect(between, isNotEmpty);
  });

  testWidgets('a broken source reports itself and leaves the others listed', (
    tester,
  ) async {
    await _pump(
      tester,
      upstream: _Upstream(sources: const [_official, _acme, _broken]),
    );
    expect(find.text('Could not load modules from bad/repo.'), findsOneWidget);
    expect(find.text('Module official-mod'), findsOneWidget);
    expect(find.text('Module extra'), findsOneWidget);
  });

  testWidgets('a module opened from a community source reads it from there', (
    tester,
  ) async {
    final upstream = await _pump(tester);
    await tester.tap(find.text('Module extra'));
    await tester.pumpAndSettle();
    expect(
      upstream.requests,
      contains('GET /space/dock/modules/extra?source=s1'),
    );
    expect(_badge('Community source: acme/mods'), findsOneWidget);
  });

  testWidgets('adding a source posts the repo slug and reloads the Dock', (
    tester,
  ) async {
    final upstream = await _pump(tester);
    await tester.tap(find.text('Add a community source'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'acme/mods');
    await tester.pump();
    await tester.tap(find.text('Add source'));
    await tester.pumpAndSettle();
    expect(upstream.bodies['POST /space/dock/sources'], {'repo': 'acme/mods'});
    expect(find.text('Add source'), findsNothing);
  });

  testWidgets(
    'a refused source shows its reason in the sheet, not a snackbar',
    (tester) async {
      final upstream = _Upstream()
        ..addResponse = _json({
          'error': {
            'code': 'bad_request',
            'message': 'a source is a GitHub owner/repo slug',
          },
        }, 400);
      await _pump(tester, upstream: upstream);
      await tester.tap(find.text('Add a community source'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(EditableText).last,
        'https://evil.example/x',
      );
      await tester.pump();
      await tester.tap(find.text('Add source'));
      await tester.pumpAndSettle();
      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Add source'), findsOneWidget);
    },
  );

  testWidgets('removing a source asks first and says installed modules stay', (
    tester,
  ) async {
    final upstream = await _pump(tester);
    await tester.tap(find.bySemanticsLabel('Remove source acme/mods'));
    await tester.pumpAndSettle();
    expect(find.textContaining('stay installed and enabled'), findsOneWidget);
    await tester.tap(find.text('Remove source').last);
    await tester.pumpAndSettle();
    expect(upstream.requests, contains('DELETE /space/dock/sources/s1'));
  });
}
