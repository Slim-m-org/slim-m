// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's page is one list: controls, Access with its Save, a folded
/// Details section and Uninstall last.
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
  List<Map<String, dynamic>> extensionPoints = const [],
}) => {
  'id': 'xp',
  'name': 'xp',
  'version': '1.0.0',
  'artifact_sha256': 'a' * 64,
  'approved_capabilities': host,
  'approved_host_capabilities': host,
  'extension_points': extensionPoints,
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

Future<void> _openDetails(WidgetTester tester) async {
  final toggle = find.byKey(const Key('dock-details-toggle'));
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pump(const Duration(milliseconds: 400));
}

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  testWidgets('a module not installed shows Access and Install, no controls', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Overview'), findsNothing);
    expect(find.text('Enabled'), findsNothing);
    expect(find.text('Access'), findsOneWidget);
    expect(find.text('Install v1.0.0'), findsOneWidget);
    expect(find.text('Remove from this space'), findsNothing);
  });

  testWidgets('an installed module reads top to bottom for an admin', (
    tester,
  ) async {
    await _pump(tester, installed: _installed());
    final order = [
      'Enabled',
      'Who can use it',
      'Access',
      'Details',
      'Remove from this space',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(
        _top(tester, order[i]),
        greaterThan(_top(tester, order[i - 1])),
        reason: '${order[i]} sits below ${order[i - 1]}',
      );
    }
  });

  testWidgets('Details folds the limits, activity and export away', (
    tester,
  ) async {
    await _pump(tester, installed: _installed(runStats: const []));
    expect(find.text('Limits per run'), findsNothing);
    expect(find.text('Activity'), findsNothing);
    expect(find.text('Export'), findsNothing);
    await _openDetails(tester);
    expect(find.text('Limits per run'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
  });

  testWidgets('the command runner is only for commands nothing else reaches', (
    tester,
  ) async {
    await _pump(
      tester,
      installed: _installed(
        extensionPoints: [
          {'kind': 'app', 'name': 'Board', 'command': 'play'},
          {'kind': 'command', 'name': 'play'},
        ],
      ),
    );
    await _openDetails(tester);
    expect(find.text('Run'), findsNothing);
  });

  testWidgets('a module of bare commands keeps its runner in Details', (
    tester,
  ) async {
    await _pump(
      tester,
      installed: _installed(
        extensionPoints: [
          {'kind': 'command', 'name': 'play'},
        ],
      ),
    );
    expect(find.text('Run'), findsNothing);
    await _openDetails(tester);
    expect(find.text('Run'), findsOneWidget);
  });

  testWidgets('a switch raises a save bar under Access, and Discard drops it', (
    tester,
  ) async {
    await _pump(tester, installed: _installed(host: ['kv.store']));
    expect(find.text('Save changes'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Post messages for xp'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1 unsaved change'), findsOneWidget);
    expect(
      _top(tester, '1 unsaved change'),
      lessThan(_top(tester, 'Details')),
      reason: 'the Save belongs to the Access switches above it',
    );

    await tester.tap(find.text('Discard'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Save changes'), findsNothing);
  });

  testWidgets('Save sends the switches that are on', (tester) async {
    final installs = await _pump(
      tester,
      installed: _installed(host: ['kv.store']),
    );
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

  testWidgets('the health banner leads the page', (tester) async {
    await _pump(
      tester,
      installed: _installed(enabled: false, reason: 'Too many failures.'),
    );
    expect(find.text('Too many failures.'), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
    expect(
      _top(tester, 'Too many failures.'),
      lessThan(_top(tester, 'Enabled')),
    );
  });
}
