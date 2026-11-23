// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A host-run connector's Dock page (decision 0134): what it asks the host to
/// run, the consent that lists it, the install that approves it without a
/// token, and the state, output and start or stop admins see once installed.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_screen.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
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
const _image = 'ghcr.io/slim-m-org/jellyfin@sha256:0123456789abcdef';
const _hostRun = {
  'image': _image,
  'egress': [
    {'host': 'jellyfin.lan', 'port': 8096},
  ],
  'egress_private': true,
  'volume': true,
  'limits': {'memory_mib': 64, 'volume_mib': 32},
};

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
  'connector': {'permissions': _asked, 'host_run': _hostRun},
  'addon_api': 7,
  'review_digest': 'd' * 64,
};

Map<String, dynamic> _installed({required bool enabled}) => {
  'id': 'jellyfin',
  'name': 'Jellyfin',
  'version': '0.1.0',
  'artifact_sha256': '',
  'approved_capabilities': <Object>[],
  'approved_host_capabilities': <Object>[],
  'extension_points': <Object>[],
  'enabled': enabled,
  'installed_at': 1,
  'provider': 'connector',
  'connector_permissions': _asked,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _Server {
  bool installed = false;
  bool enabled = false;
  bool configured = true;
  final installs = <Map<String, dynamic>>[];
  final toggles = <String>[];
  int statusReads = 0;
}

Future<_Server> _pump(
  WidgetTester tester, {
  bool installed = false,
  bool configured = true,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server()
    ..installed = installed
    ..configured = configured;
  final container = ProviderContainer(
    overrides: [
      ...overrides,
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        final path = request.url.path;
        if (path == '/space/dock/modules') return _json(<Object>[]);
        if (path == '/space/dock/installed') {
          return _json([
            if (server.installed) _installed(enabled: server.enabled),
          ]);
        }
        if (path == '/space/dock/modules/jellyfin') return _json(_manifest());
        if (path == '/space/dock/connector-runtime') {
          return _json({
            'configured': server.configured,
            'available': server.configured,
          });
        }
        if (path == '/space/dock/modules/jellyfin/install') {
          server.installs.add(jsonDecode(request.body) as Map<String, dynamic>);
          server.installed = true;
          return _json(_installed(enabled: false));
        }
        if (path == '/space/dock/modules/jellyfin/host-run') {
          server.statusReads++;
          return _json({
            ..._hostRun,
            'state': 'disabled_after_crashes',
            'oom_killed': false,
            'restarts': 5,
            'last_error': 'Turned off after 5 crashes within 10 minutes.',
          });
        }
        if (path == '/space/dock/modules/jellyfin/host-run/logs') {
          return _json({
            'lines': [
              {'ts': 't', 'stream': 'stderr', 'text': 'cannot reach jellyfin'},
            ],
          });
        }
        if (path == '/space/dock/modules/jellyfin/enable' ||
            path == '/space/dock/modules/jellyfin/disable') {
          server.toggles.add(path.split('/').last);
          server.enabled = path.endsWith('enable');
          return _json(_installed(enabled: server.enabled));
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
          initialLocation: '${Routes.adminDock}/jellyfin',
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
  await _settle(tester);
  return server;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('the status is not polled while the window is minimised', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final events = StreamController<DesktopWindowEventKind>(sync: true);
    addTearDown(events.close);
    final window = AppLifecycleNotifier(
      mobile: false,
      windowEvents: events.stream,
    );
    final server = await _pump(
      tester,
      installed: true,
      overrides: [appLifecycleProvider.overrideWith((ref) => window)],
    );
    await tester.pump(const Duration(seconds: 6));
    expect(server.statusReads, greaterThan(1), reason: 'it polls in view');

    events.add(DesktopWindowEventKind.minimize);
    await tester.pump();
    final hidden = server.statusReads;
    await tester.pump(const Duration(seconds: 11));
    expect(server.statusReads, hidden);
  });

  testWidgets('before install the page shows what the host would run', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Run by this server'), findsOneWidget);
    expect(find.text(_image), findsOneWidget);
    expect(find.text('Your server, jellyfin.lan:8096'), findsOneWidget);
    expect(find.text('None open to the outside'), findsOneWidget);
    expect(find.text('64 MB memory, 0.5 CPU, 64 processes'), findsOneWidget);
    expect(find.text('Its own data folder, up to 32 MB'), findsOneWidget);
    expect(find.text('Runs in a sandbox on this server.'), findsOneWidget);
  });

  testWidgets('a server without the runtime says so before install', (
    tester,
  ) async {
    await _pump(tester, configured: false);
    expect(find.textContaining('not set up to run connectors'), findsOneWidget);
  });

  testWidgets('the consent lists the ask and the install sends no token', (
    tester,
  ) async {
    final server = await _pump(tester);
    await tester.tap(find.text('Install v0.1.0'));
    await _settle(tester);
    expect(find.text('Install Jellyfin?'), findsOneWidget);
    expect(
      find.textContaining('runs this connector in a sandbox'),
      findsOneWidget,
    );
    expect(find.text(_image), findsNWidgets(2));
    await tester.tap(find.widgetWithText(AppButton, 'Install'));
    await _settle(tester);
    expect(server.installs.single['approved_host_run'], {
      'egress': [
        {'host': 'jellyfin.lan', 'port': 8096},
      ],
      'egress_private': true,
    });
    expect(find.text('Copy token'), findsNothing);
    expect(find.text('New token'), findsNothing);
    await expireToasts(tester);
  });

  testWidgets('an installed connector shows its state, reason and output', (
    tester,
  ) async {
    final server = await _pump(tester, installed: true);
    expect(find.text('Turned off after crashing'), findsOneWidget);
    expect(
      find.text('Turned off after 5 crashes within 10 minutes.'),
      findsOneWidget,
    );
    expect(find.text('5 in the last 10 minutes'), findsOneWidget);
    expect(find.text('cannot reach jellyfin'), findsOneWidget);
    final start = find.widgetWithText(AppButton, 'Start');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await _settle(tester);
    expect(server.toggles, ['enable']);
    await expireToasts(tester);
  });
}
