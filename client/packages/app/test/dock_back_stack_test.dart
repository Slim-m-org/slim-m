// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opening a module from the Dock and backing out must leave the app under
/// the panel, not the bare scrim: the row used to `go` (replace the stack),
/// so the page below the Dock was gone and back showed black.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/admin/dock_module_screen.dart';
import 'package:slimm_app/src/screens/admin/dock_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _entry = {
  'id': 'dice',
  'name': 'Dice',
  'version': '1.0.0',
  'summary': 'Roll some dice.',
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = MockClient((request) async {
    switch (request.url.path) {
      case '/space/dock/modules':
        return _json([_entry]);
      case '/space/dock/installed':
        return _json(<Object>[]);
    }
    return http.Response('{}', 404);
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'admin',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      ),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: client,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('app below', key: Key('below'))),
        ),
      ),
      GoRoute(
        path: Routes.adminDock,
        pageBuilder: (c, s) => modalPage(c, const DockScreen()),
      ),
      GoRoute(
        path: '${Routes.adminDock}/:moduleId',
        pageBuilder: (c, s) => modalPage(
          c,
          DockModuleScreen(moduleId: s.pathParameters['moduleId']!),
        ),
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
  unawaited(router.push(Routes.adminDock));
  await tester.pumpAndSettle();
}

void main() {
  for (final (label, size) in [
    ('desktop', const Size(1400, 900)),
    ('phone', const Size(400, 800)),
  ]) {
    testWidgets('$label: opening a module and going back keeps the app below', (
      tester,
    ) async {
      await _pump(tester, size);
      await tester.tap(find.text('Dice'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back to Modules'), findsOneWidget);

      await tester.tap(find.byTooltip('Back to Modules'));
      await tester.pumpAndSettle();
      expect(find.text('Dice'), findsOneWidget, reason: 'back on the Dock');

      await tester.tap(find.byTooltip('Back to Space settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('below')), findsOneWidget);
    });
  }
}
