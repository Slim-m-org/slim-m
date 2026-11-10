// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The host access an admin approves on a module's Dock page
/// (docs/decisions/0023): the switches list what the module declared, start
/// off for a first install, and only what is on is sent.
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
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/dock_page_helpers.dart';
import '../../ui_snapshot_support.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _sha = List.filled(64, 'a').join();

Map<String, dynamic> _manifest([Map<String, dynamic> extras = const {}]) => {
  'id': 'ladder',
  'name': 'Ladder',
  'version': '0.1.0',
  'summary': 'Keeps a win ladder.',
  'artifact': {
    'kind': 'wasm',
    'path': 'modules/ladder/module.wasm',
    'sha256': _sha,
  },
  'runtime': {
    'backend': 'wasm',
    'limits': {'memory_mb': 32, 'wall_ms': 1000, 'fuel': 100000000},
  },
  'permissions': [
    {'key': 'play', 'name': 'Play', 'description': 'Take part.'},
  ],
  'capabilities': ['kv.store', 'message.post', 'surface.render'],
  'extension_points': [
    {'kind': 'command', 'name': 'run', 'permission': 'play'},
  ],
  ...extras,
};

Map<String, dynamic> _installedRow(
  List<String> approvedHost, {
  String? sha,
  Map<String, dynamic> extras = const {},
}) => {
  'id': 'ladder',
  'name': 'Ladder',
  'version': '0.1.0',
  'artifact_sha256': sha ?? _sha,
  'approved_capabilities': ['kv.store', 'message.post', 'surface.render'],
  'approved_host_capabilities': approvedHost,
  'extension_points': <Map<String, dynamic>>[],
  'enabled': true,
  'installed_at': 1000,
  ...extras,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// Pumps the module's Dock page, installed with [installedApproved] or, when
/// null, not installed. Every install request body lands in the returned list.
Future<List<Map<String, dynamic>>> _pump(
  WidgetTester tester, {
  List<String>? installedApproved,
  String? installedSha,
  Map<String, dynamic> manifestExtras = const {},
  Map<String, dynamic> installedExtras = const {},
  Size size = const Size(420, 1400),
}) async {
  final installs = <Map<String, dynamic>>[];
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/space/dock/modules') {
      return _json([
        {'id': 'ladder', 'name': 'Ladder', 'version': '0.1.0', 'summary': 's'},
      ]);
    }
    if (path == '/space/dock/installed') {
      return _json([
        if (installedApproved != null)
          _installedRow(
            installedApproved,
            sha: installedSha,
            extras: installedExtras,
          ),
      ]);
    }
    if (path == '/space/dock/modules/ladder') {
      return _json(_manifest(manifestExtras));
    }
    if (path == '/space/dock/modules/ladder/install') {
      installs.add(jsonDecode(request.body) as Map<String, dynamic>);
      return _json(_installedRow(const []));
    }
    if (path == '/roles' || path.contains('module-permissions')) {
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

  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: GoRouter(
            initialLocation: '${Routes.adminDock}/ladder',
            routes: [
              GoRoute(
                path: Routes.adminDock,
                builder: (context, state) => const SizedBox.shrink(),
              ),
              GoRoute(
                path: '${Routes.adminDock}/:moduleId',
                builder: (context, state) => DockModuleScreen(
                  moduleId: state.pathParameters['moduleId']!,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return installs;
}

List<bool> _switches(WidgetTester tester) => [
  for (final toggle in tester.widgetList<AppToggle>(find.byType(AppToggle)))
    if (toggle.semanticLabel?.endsWith(' for Ladder') ?? false) toggle.value,
];

void main() {
  testWidgets('a first install lists what the host can grant, all off', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Access'), findsNothing, reason: 'asked when installing');
    await openInstallAccess(tester);
    expect(find.text('Access'), findsOneWidget);
    expect(find.text('Remember data'), findsOneWidget);
    expect(find.text('Post messages'), findsOneWidget);
    await openDockFold(tester, 'details');
    expect(
      find.text('SURFACE.RENDER'),
      findsOneWidget,
      reason: 'still named in the asks, but with no switch to approve it',
    );
    expect(_switches(tester), [false, false]);
    await writeSnapshot(tester, 'dock-host-access-first-install-phone');
  });

  testWidgets('the same page at desktop width', (tester) async {
    await _pump(tester, size: const Size(1100, 1000));
    await writeSnapshot(tester, 'dock-host-access-first-install-desktop');
  });

  testWidgets('install sends only the switches that are on', (tester) async {
    final installs = await _pump(tester);
    await openInstallAccess(tester);
    await tester.tap(find.byType(AppToggle).at(1));
    await tester.pumpAndSettle();
    expect(_switches(tester), [false, true]);

    await confirmInstallAccess(tester);
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(installs.single['approved_host_capabilities'], ['message.post']);
  });

  testWidgets('an installed module shows what was approved and saves changes', (
    tester,
  ) async {
    final installs = await _pump(tester, installedApproved: ['kv.store']);
    expect(_switches(tester).sublist(0, 2), [true, false]);
    expect(find.text('Save changes'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Post messages for Ladder'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    await writeSnapshot(tester, 'dock-host-access-installed-changed-phone');

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(installs.single['approved_host_capabilities'], [
      'kv.store',
      'message.post',
    ]);
  });

  testWidgets('a new build must be approved for posting again', (tester) async {
    final installs = await _pump(
      tester,
      installedApproved: ['kv.store', 'message.post'],
      installedSha: List.filled(64, 'b').join(),
    );
    expect(_switches(tester).sublist(0, 2), [true, false]);
    expect(
      find.text('This version needs Post messages approved again.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(installs.single['approved_host_capabilities'], ['kv.store']);
  });

  group('a hook on the same version', () {
    Map<String, dynamic> hook(List<String> reads) => {
      'interceptors': [
        {'hook': 'message.pre_send', 'phase': 'reject', 'reads': reads},
      ],
    };
    final offered = {
      'capabilities': ['kv.store', 'interceptors'],
      ...hook(['channel_id', 'content']),
    };

    testWidgets('that reads more must be approved again', (tester) async {
      await _pump(
        tester,
        installedApproved: ['kv.store', 'interceptors'],
        manifestExtras: offered,
        installedExtras: hook(['channel_id']),
      );

      expect(_switches(tester), [true, false]);
      expect(
        find.text('This version needs Check messages approved again.'),
        findsOneWidget,
      );
    });

    testWidgets('that reads the same stays approved', (tester) async {
      await _pump(
        tester,
        installedApproved: ['kv.store', 'interceptors'],
        manifestExtras: offered,
        installedExtras: hook(['channel_id', 'content']),
      );

      expect(_switches(tester), [true, true]);
      expect(find.textContaining('approved again'), findsNothing);
    });
  });

  testWidgets('desktop: Overview and a changed Access tab', (tester) async {
    await _pump(
      tester,
      installedApproved: ['kv.store'],
      size: const Size(1100, 1000),
    );
    await writeSnapshot(tester, 'dock-module-overview-desktop');
    await tester.tap(find.bySemanticsLabel('Post messages for Ladder'));
    await tester.pump(const Duration(milliseconds: 400));
    await writeSnapshot(tester, 'dock-module-access-changed-desktop');
  });
}
