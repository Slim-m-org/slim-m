// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock's search field: a marketplace of nine modules is a scroll, and
/// finding one by what it does matters as much as by what it is called, so
/// the summary is searched alongside the name and the id.
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

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _entry(String id, String name, String summary) => {
  'id': id,
  'name': name,
  'version': '1.0.0',
  'summary': summary,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
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

void main() {
  testWidgets('search narrows the list by name, by id and by summary', (
    tester,
  ) async {
    final client = MockClient((request) async {
      if (request.url.path == '/space/dock/modules') {
        return _json([
          _entry('code-exec', 'Code Blocks', 'Run a code block inline.'),
          _entry('dice', 'Dice', 'Roll dice notation like 2d20+3.'),
          _entry('game-of-life', 'Game of Life', 'Conway cellular automata.'),
        ]);
      }
      if (request.url.path == '/space/dock/installed') {
        return _json(<Map<String, dynamic>>[]);
      }
      throw StateError('unexpected request: ${request.url}');
    });
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api_ = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(api_.close);
          return api_;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    expect(find.text('Code Blocks'), findsOneWidget);
    expect(find.text('Dice'), findsOneWidget);
    expect(find.text('Game of Life'), findsOneWidget);

    // By name, case-insensitively.
    await tester.enterText(find.byType(TextField), 'dice');
    await tester.pumpAndSettle();
    expect(find.text('Dice'), findsOneWidget);
    expect(find.text('Code Blocks'), findsNothing);

    // By what it does, not only what it is called.
    await tester.enterText(find.byType(TextField), 'cellular');
    await tester.pumpAndSettle();
    expect(find.text('Game of Life'), findsOneWidget);
    expect(find.text('Dice'), findsNothing);

    // By id, for an admin who knows the module rather than its display name.
    await tester.enterText(find.byType(TextField), 'code-exec');
    await tester.pumpAndSettle();
    expect(find.text('Code Blocks'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nothing matches this');
    await tester.pumpAndSettle();
    expect(find.textContaining('No module matches'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Dice'), findsOneWidget);
    expect(find.text('Game of Life'), findsOneWidget);
  });
}
