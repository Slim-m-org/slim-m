// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An installed module's own controls: enable, disable, uninstall and the way
/// to choose who may use it, each through the real client bindings.
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
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _sha = List.filled(64, 'a').join();

const _entry = {
  'id': 'dice',
  'name': 'Dice',
  'version': '1.0.0',
  'summary': 'Rolls dice.',
};

Map<String, dynamic> _manifest({bool withPermission = true}) => {
  ..._entry,
  'artifact': {'kind': 'wasm', 'path': 'dice.wasm', 'sha256': _sha},
  'runtime': {'backend': 'wasm', 'limits': <String, dynamic>{}},
  'permissions': [
    if (withPermission)
      {'key': 'roll', 'name': 'Roll dice', 'description': 'Roll in a channel.'},
  ],
  'capabilities': ['command.register'],
  'extension_points': <Object>[],
};

Map<String, dynamic> _installed({required bool enabled}) => {
  'id': 'dice',
  'name': 'Dice',
  'version': '1.0.0',
  'artifact_sha256': _sha,
  'approved_capabilities': ['command.register'],
  'extension_points': <Object>[],
  'enabled': enabled,
  'installed_at': 1000,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

typedef _Call = (String method, String path);

class _Harness {
  _Harness({required this.enabled, this.withPermission = true});

  bool enabled;
  final bool withPermission;
  bool installed = true;
  final calls = <_Call>[];
  int? failStatus;

  http.Response handle(http.Request request) {
    final path = request.url.path;
    calls.add((request.method, path));
    if (path == '/space/dock/modules') return _json([_entry]);
    if (path == '/space/dock/installed') {
      return _json(installed ? [_installed(enabled: enabled)] : <Object>[]);
    }
    if (path == '/space/dock/modules/dice') {
      return _json(_manifest(withPermission: withPermission));
    }
    if (request.method == 'POST' && path.endsWith('/enable')) {
      if (failStatus != null) return http.Response('down', failStatus!);
      enabled = true;
      return _json(_installed(enabled: true));
    }
    if (request.method == 'POST' && path.endsWith('/disable')) {
      enabled = false;
      return _json(_installed(enabled: false));
    }
    if (request.method == 'DELETE') {
      installed = false;
      return http.Response('', 204);
    }
    if (path == '/roles') return _json(<Object>[]);
    throw StateError('unexpected request: ${request.method} ${request.url}');
  }

  List<String> posted(String method) => [
    for (final (m, p) in calls)
      if (m == method) p,
  ];
}

Future<void> _open(WidgetTester tester, _Harness harness) async {
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((r) async => harness.handle(r)),
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
  await tester.tap(find.text('Dice'));
  await tester.pumpAndSettle();
}

AppToggle _enabledToggle(WidgetTester tester) => tester
    .widgetList<AppToggle>(find.byType(AppToggle))
    .firstWhere((t) => t.semanticLabel!.startsWith('Dice '));

void main() {
  testWidgets('switching an installed module on posts to the enable route', (
    tester,
  ) async {
    final harness = _Harness(enabled: false);
    await _open(tester, harness);
    _enabledToggle(tester).onChanged!(true);
    await tester.pumpAndSettle();
    expect(harness.posted('POST'), ['/space/dock/modules/dice/enable']);
    expect(_enabledToggle(tester).value, isTrue);
  });

  testWidgets('switching an enabled module off posts to the disable route', (
    tester,
  ) async {
    final harness = _Harness(enabled: true);
    await _open(tester, harness);
    _enabledToggle(tester).onChanged!(false);
    await tester.pumpAndSettle();
    expect(harness.posted('POST'), ['/space/dock/modules/dice/disable']);
    expect(_enabledToggle(tester).value, isFalse);
  });

  testWidgets('a refused enable stays on the page as a persistent error', (
    tester,
  ) async {
    final harness = _Harness(enabled: false)..failStatus = 500;
    await _open(tester, harness);
    _enabledToggle(tester).onChanged!(true);
    await tester.pumpAndSettle();
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
    'uninstalling asks first and deletes the install once confirmed',
    (tester) async {
      final harness = _Harness(enabled: true);
      await _open(tester, harness);

      await tester.tap(find.widgetWithText(AppButton, 'Uninstall'));
      await tester.pumpAndSettle();
      expect(find.text('Uninstall Dice?'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(harness.posted('DELETE'), isEmpty);

      await tester.tap(find.widgetWithText(AppButton, 'Uninstall'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppButton, 'Uninstall').last);
      await tester.pumpAndSettle();
      expect(harness.posted('DELETE'), ['/space/dock/modules/dice/install']);
      expect(find.text('Modules'), findsWidgets);
      expect(find.text('Uninstall'), findsNothing);
    },
  );

  testWidgets('a module with permissions offers choosing who can use it', (
    tester,
  ) async {
    await _open(tester, _Harness(enabled: true));
    await tester.tap(find.widgetWithText(AppButton, 'Choose who can use this'));
    await tester.pumpAndSettle();
    expect(find.text('Who can use this'), findsOneWidget);
  });

  testWidgets('a module without permissions has nobody to choose', (
    tester,
  ) async {
    await _open(tester, _Harness(enabled: true, withPermission: false));
    expect(find.text('Choose who can use this'), findsNothing);
    expect(find.widgetWithText(AppButton, 'Uninstall'), findsOneWidget);
  });
}
