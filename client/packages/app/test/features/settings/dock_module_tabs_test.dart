// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's page is three tabs, a health banner above them, and a Save that
/// belongs to the Access tab.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../dock_manifest_fixture.dart';
import '../../support/dock_page_helpers.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _installed({
  List<String> host = const [],
  bool enabled = true,
  String? reason,
  List<Map<String, dynamic>>? runStats,
}) => {
  'id': 'xp',
  'name': 'xp',
  'version': '1.0.0',
  'artifact_sha256': 'a' * 64,
  'approved_capabilities': host,
  'approved_host_capabilities': host,
  'extension_points': <Object>[],
  'enabled': enabled,
  'installed_at': 1,
  'disabled_reason': ?reason,
  'run_stats': ?runStats,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// Opens the module page; [installed] is the row the server holds, if any.
Future<List<Map<String, dynamic>>> _pump(
  WidgetTester tester, {
  Map<String, dynamic>? installed,
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final installs = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        final path = request.url.path;
        if (path == '/space/dock/modules') return _json(<Object>[]);
        if (path == '/space/dock/installed') return _json([?installed]);
        if (path == '/space/dock/modules/xp') {
          return _json(
            dockManifestJson(
              'xp',
              '1.0.0',
              capabilities: ['kv.store', 'message.post'],
            ),
          );
        }
        if (path == '/space/dock/modules/xp/install') {
          installs.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _json(_installed(host: ['kv.store', 'message.post']));
        }
        if (path == '/roles' || path.contains('module-permissions')) {
          return _json(<Object>[]);
        }
        throw StateError('unexpected ${request.method} $path');
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
          initialLocation: '${Routes.adminDock}/xp',
          routes: [
            GoRoute(
              path: '${Routes.adminDock}/:moduleId',
              builder: (context, state) =>
                  DockModuleScreen(moduleId: state.pathParameters['moduleId']!),
            ),
          ],
        ),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
  return installs;
}

void main() {
  testWidgets('a module not installed has Overview and Access only', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Access'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Install v1.0.0'), findsOneWidget);
    await openDockTab(tester, 'Access');
    expect(
      find.text('Install v1.0.0'),
      findsOneWidget,
      reason: 'Install stays under every tab, so switches can be set first',
    );
  });

  testWidgets('Overview holds the actions and Access holds the grants', (
    tester,
  ) async {
    await _pump(tester, installed: _installed());
    expect(find.text('Actions'), findsOneWidget);
    expect(find.text('Access to approve'), findsNothing);
    await openDockTab(tester, 'Access');
    expect(find.text('Actions'), findsNothing);
    expect(find.text('Access to approve'), findsOneWidget);
    expect(find.text('Limits on every run'), findsOneWidget);
  });

  testWidgets('Settings appears once the module has something to show', (
    tester,
  ) async {
    await _pump(tester, installed: _installed(runStats: const []));
    expect(find.text('Settings'), findsOneWidget);
    await openDockTab(tester, 'Settings');
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Actions'), findsNothing);
  });

  testWidgets('a switch raises a save bar on Access, and Discard drops it', (
    tester,
  ) async {
    await _pump(tester, installed: _installed(host: ['kv.store']));
    await openDockTab(tester, 'Access');
    expect(find.text('Save changes'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Post messages for xp'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1 unsaved change'), findsOneWidget);
    await openDockTab(tester, 'Overview');
    expect(find.text('Save changes'), findsNothing);
    await openDockTab(tester, 'Access');
    expect(find.text('1 unsaved change'), findsOneWidget);

    await tester.tap(find.text('Discard'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Save changes'), findsNothing);
  });

  testWidgets('Save sends the switches that are on', (tester) async {
    final installs = await _pump(
      tester,
      installed: _installed(host: ['kv.store']),
    );
    await openDockTab(tester, 'Access');
    await tester.tap(find.bySemanticsLabel('Post messages for xp'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Save changes'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(AppButton, 'Update'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(installs.single['approved_host_capabilities'], [
      'kv.store',
      'message.post',
    ]);
  });

  testWidgets('the health banner stays above every tab', (tester) async {
    await _pump(
      tester,
      installed: _installed(enabled: false, reason: 'Too many failures.'),
    );
    expect(find.text('Too many failures.'), findsOneWidget);
    await openDockTab(tester, 'Access');
    expect(find.text('Too many failures.'), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
  });
}
