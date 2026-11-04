// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Modules list is one list at a time: Installed or Browse, with the
/// install-from-file and source actions behind the overflow menu.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/dock_page_helpers.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _entry(String id) => {
  'id': id,
  'name': 'Module $id',
  'version': '1.0.0',
  'summary': 'Summary of $id.',
};

Map<String, dynamic> _installed(String id, {bool enabled = true}) => {
  'id': id,
  'name': 'Module $id',
  'version': '1.0.0',
  'artifact_sha256': 'a' * 64,
  'approved_capabilities': <String>[],
  'extension_points': <Object>[],
  'enabled': enabled,
  'installed_at': 1,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _pump(
  WidgetTester tester, {
  List<String> installed = const [],
  List<String> disabled = const [],
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        return switch (request.url.path) {
          '/space/dock/modules' => _json([_entry('a'), _entry('b')]),
          '/space/dock/installed' => _json([
            for (final id in installed) _installed(id),
            for (final id in disabled) _installed(id, enabled: false),
          ]),
          '/space/dock/sources' => _json(<Object>[]),
          _ => throw StateError('unexpected ${request.url.path}'),
        };
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
          ],
        ),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('with nothing installed the list opens on Browse', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Module a'), findsOneWidget);
    expect(find.text('Module b'), findsOneWidget);
    expect(find.text('Module display'), findsNothing);
  });

  testWidgets('with something installed it opens on Installed only', (
    tester,
  ) async {
    await _pump(tester, installed: ['a']);
    expect(find.text('Module a'), findsOneWidget);
    expect(find.text('Module b'), findsNothing);
    expect(find.text('INSTALLED'), findsNothing);
  });

  testWidgets('Browse lists every module and marks the installed one', (
    tester,
  ) async {
    await _pump(tester, installed: ['a']);
    await openDockTab(tester, 'Browse');
    expect(find.text('Module a'), findsOneWidget);
    expect(find.text('Module b'), findsOneWidget);
    expect(find.text('INSTALLED'), findsOneWidget);
    await openDockTab(tester, 'Installed');
    expect(find.text('Module b'), findsNothing);
  });

  testWidgets('a disabled module says Off on the Installed list', (
    tester,
  ) async {
    await _pump(tester, disabled: ['a']);
    expect(find.text('OFF'), findsOneWidget);
  });

  testWidgets('search narrows the Installed list too', (tester) async {
    await _pump(tester, installed: ['a', 'b']);
    await tester.enterText(
      find.byWidgetPredicate((w) => w is EditableText),
      'Summary of b',
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Module a'), findsNothing);
    expect(find.text('Module b'), findsOneWidget);
  });

  testWidgets('the overflow menu holds files and sources', (tester) async {
    await _pump(tester, installed: ['a']);
    expect(find.text('Install from a file'), findsNothing);
    expect(find.text('Add a community source'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Module options'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Install from a file'), findsOneWidget);
    expect(find.text('Add a community source'), findsOneWidget);
    expect(find.text('Manage sources'), findsOneWidget);
  });

  testWidgets('Module display is one row that opens the two switches', (
    tester,
  ) async {
    await _pump(tester, installed: ['a']);
    expect(find.text('Badges in member list'), findsNothing);
    await tester.tap(find.text('Module display'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Badges in member list'), findsOneWidget);
    expect(find.text('Sections on profiles'), findsOneWidget);
  });
}
