// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A connector's Dock page (decision 0090): what its token asks for, the
/// consent that lists it, the install that approves it, and the token shown
/// once with a way to make a new one.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_screen.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import '../../support/toast_host.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _asked = Perm.viewChannel | Perm.sendMessages;

Map<String, dynamic> _manifest() => {
  'id': 'jellyfin',
  'name': 'Jellyfin',
  'version': '0.1.0',
  'summary': 'Posts what is playing.',
  'artifact': {'kind': 'connector', 'path': '', 'sha256': ''},
  'runtime': {'backend': 'connector', 'limits': <String, Object>{}},
  'permissions': <Object>[],
  'capabilities': <Object>[],
  'extension_points': <Object>[],
  'provider': 'connector',
  'connector': {'permissions': _asked},
  'addon_api': 7,
  'review_digest': 'd' * 64,
};

Map<String, dynamic> _installed({String? token}) => {
  'id': 'jellyfin',
  'name': 'Jellyfin',
  'version': '0.1.0',
  'artifact_sha256': '',
  'approved_capabilities': <Object>[],
  'approved_host_capabilities': <Object>[],
  'extension_points': <Object>[],
  'enabled': true,
  'installed_at': 1,
  'provider': 'connector',
  'connector_permissions': _asked,
  'connector_token': ?token,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _Server {
  bool installed = false;
  Completer<void>? installGate;
  late final GoRouter router;
  final installs = <Map<String, dynamic>>[];
  int reissues = 0;
}

Future<_Server> _pump(
  WidgetTester tester, {
  bool installed = false,
  Completer<void>? installGate,
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server()
    ..installed = installed
    ..installGate = installGate;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        final path = request.url.path;
        if (path == '/space/dock/modules') return _json(<Object>[]);
        if (path == '/space/dock/installed') {
          return _json([if (server.installed) _installed()]);
        }
        if (path == '/space/dock/modules/jellyfin') return _json(_manifest());
        if (path == '/space/dock/modules/jellyfin/install') {
          await server.installGate?.future;
          server.installs.add(jsonDecode(request.body) as Map<String, dynamic>);
          server.installed = true;
          return _json(_installed(token: 'slimbot_first'));
        }
        if (path == '/space/dock/modules/jellyfin/enable') {
          return _json(_installed());
        }
        if (path == '/space/dock/modules/jellyfin/connector-token') {
          server.reissues++;
          return _json({'token': 'slimbot_second'});
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
        routerConfig: server.router = GoRouter(
          initialLocation: '${Routes.adminDock}/jellyfin',
          routes: [
            GoRoute(path: '/away', builder: (_, _) => const SizedBox()),
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
  await _settle(tester);
  return server;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('the page says what the token asks for, not host access', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Token access'), findsOneWidget);
    expect(find.text('Asks to'), findsOneWidget);
    expect(find.text('View channels and Send messages'), findsOneWidget);
    expect(find.text('Access'), findsNothing);
    expect(find.text('Limits per run'), findsNothing);
  });

  testWidgets('installing approves the ask and shows the token once', (
    tester,
  ) async {
    final server = await _pump(tester);
    await tester.tap(find.text('Install v0.1.0'));
    await _settle(tester);
    expect(find.text('Install Jellyfin?'), findsOneWidget);
    expect(find.text('View channels'), findsOneWidget);
    expect(find.text('Send messages'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Install'));
    await _settle(tester);

    expect(server.installs, hasLength(1));
    expect(server.installs.single['approved_connector_permissions'], _asked);
    expect(server.installs.single['reviewed_digest'], 'd' * 64);
    expect(find.text('slimbot_first'), findsOneWidget);
    expect(find.text('Copy token'), findsOneWidget);
    expect(find.text('Can'), findsOneWidget);
    expect(toastMessages(tester), ['Jellyfin installed']);
    await expireToasts(tester);
  });

  testWidgets('a token minted after the admin left is still there on return', (
    tester,
  ) async {
    final gate = Completer<void>();
    final server = await _pump(tester, installGate: gate);
    await tester.tap(find.text('Install v0.1.0'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Install'));
    await tester.pump();

    server.router.go('/away');
    await _settle(tester);
    gate.complete();
    await _settle(tester);
    server.router.go('${Routes.adminDock}/jellyfin');
    await _settle(tester);

    expect(find.text('slimbot_first'), findsOneWidget);
  });

  testWidgets('declining the consent installs nothing', (tester) async {
    final server = await _pump(tester);
    await tester.tap(find.text('Install v0.1.0'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await _settle(tester);
    expect(server.installs, isEmpty);
    expect(find.text('Copy token'), findsNothing);
  });

  testWidgets('a new token replaces the old one after a confirm', (
    tester,
  ) async {
    final server = await _pump(tester, installed: true);
    expect(find.text('Copy token'), findsNothing, reason: 'never shown again');
    final button = find.widgetWithText(AppButton, 'New token');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await _settle(tester);
    await tester.tap(find.widgetWithText(AppButton, 'New token').last);
    await _settle(tester);
    expect(server.reissues, 1);
    expect(find.text('slimbot_second'), findsOneWidget);
  });
}
