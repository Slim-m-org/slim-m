// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What an admin reads on the Dock before approving a module: which version is
/// on offer, every limit the manifest asks for, only capabilities that grant
/// something, one inset across the cards, and a confirmation once it is in.
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
import 'package:slimm_app/src/screens/admin/dock_limits_card.dart';
import 'package:slimm_app/src/screens/admin/dock_module_access_screen.dart';
import 'package:slimm_app/src/screens/admin/dock_module_screen.dart';
import 'package:slimm_app/src/screens/admin/dock_screen.dart';
import 'package:slimm_app/src/widgets/settings_section_header.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _sha = List.filled(64, 'a').join();

Map<String, dynamic> _entry(String version) => {
  'id': 'dice',
  'name': 'Dice',
  'version': version,
  'summary': 'Roll dice notation like 2d20+3.',
};

Map<String, dynamic> _manifest({
  required String version,
  required List<String> capabilities,
  required Map<String, dynamic> limits,
}) => {
  ..._entry(version),
  'author': 'slim-m',
  'artifact': {
    'kind': 'wasm',
    'path': 'modules/dice/module.wasm',
    'sha256': _sha,
  },
  'runtime': {'backend': 'wasm', 'limits': limits},
  'permissions': [
    {'key': 'roll', 'name': 'Roll dice', 'description': 'Roll and post.'},
  ],
  'capabilities': capabilities,
  'extension_points': [
    {'kind': 'slash-command', 'name': 'roll', 'command': 'roll'},
  ],
};

Map<String, dynamic> _installed(String version) => {
  'id': 'dice',
  'name': 'Dice',
  'version': version,
  'artifact_sha256': _sha,
  'approved_capabilities': ['command.register'],
  'extension_points': <Map<String, dynamic>>[],
  'enabled': true,
  'installed_at': 1000,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  String? installedVersion,
  List<String> capabilities = const ['command.register'],
  Map<String, dynamic> limits = const {
    'memory_mb': 64,
    'wall_ms': 2000,
    'fuel': 2000000000,
  },
  String location = Routes.adminDock,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var installed = installedVersion;
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/space/dock/modules') return _json([_entry('0.3.1')]);
    if (path == '/space/dock/installed') {
      return _json([if (installed != null) _installed(installed!)]);
    }
    if (path == '/space/dock/modules/dice') {
      return _json(
        _manifest(version: '0.3.1', capabilities: capabilities, limits: limits),
      );
    }
    if (path == '/space/dock/modules/dice/install') {
      installed = '0.3.1';
      return _json(_installed('0.3.1'));
    }
    if (path == '/space/dock/modules/dice/enable') {
      return _json(_installed('0.3.1'));
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
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: GoRouter(
          initialLocation: location,
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
}

const _modulePage = '${Routes.adminDock}/dice';

void main() {
  testWidgets('the badge says an update is available, the row says which', (
    tester,
  ) async {
    await _pump(tester, width: 800, installedVersion: '0.1.0');
    expect(find.text('UPDATE AVAILABLE'), findsOneWidget);
    expect(find.text('V0.1.0 · UPDATE'), findsNothing);
    expect(find.text('Installed v0.1.0, latest v0.3.1'), findsOneWidget);
  });

  testWidgets('the install screen shows memory, time and CPU limits', (
    tester,
  ) async {
    await _pump(tester, width: 800, location: _modulePage);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('64 MB'), findsOneWidget);
    expect(find.text('Time'), findsOneWidget);
    expect(find.text('2 seconds'), findsOneWidget);
    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('about 2 billion instructions'), findsOneWidget);
  });

  testWidgets('a limit the manifest leaves out is the host default', (
    tester,
  ) async {
    await _pump(tester, width: 800, location: _modulePage, limits: const {});
    expect(find.text('host default'), findsNWidgets(3));
  });

  testWidgets('command.register is not listed as something to approve', (
    tester,
  ) async {
    await _pump(tester, width: 800, location: _modulePage);
    expect(find.text('COMMAND.REGISTER'), findsNothing);
    expect(find.text(dockNoAccessNote), findsOneWidget);
  });

  testWidgets('a grantable capability keeps its switch and no chip', (
    tester,
  ) async {
    await _pump(
      tester,
      width: 800,
      location: _modulePage,
      capabilities: const ['command.register', 'message.post'],
    );
    expect(find.text('Post messages'), findsOneWidget);
    expect(find.text('MESSAGE.POST'), findsNothing);
    expect(find.text(dockNoAccessNote), findsNothing);
  });

  for (final width in [390.0, 800.0, 1280.0]) {
    testWidgets('the search field is as wide as the cards at $width', (
      tester,
    ) async {
      await _pump(tester, width: width, installedVersion: '0.1.0');
      final card = tester.getRect(find.byType(SettingsSectionCard).first);
      final field = tester.getRect(find.byType(AppInput));
      // The 2px focus ring plus its 2px gutter are reserved outside the box.
      expect(field.left, card.left - 4);
      expect(field.right, card.right + 4);
    });

    testWidgets('card text starts at one inset on the module page at $width', (
      tester,
    ) async {
      await _pump(
        tester,
        width: width,
        installedVersion: '0.3.1',
        location: _modulePage,
        capabilities: const ['command.register', 'message.post'],
      );
      final lefts = {
        for (final label in ['Roll dice', 'Remember data', 'Memory', 'Enabled'])
          if (find.text(label).evaluate().isNotEmpty)
            label: tester.getTopLeft(find.text(label)).dx,
      };
      expect(lefts.keys, containsAll(['Roll dice', 'Memory', 'Enabled']));
      expect(lefts.values.toSet(), hasLength(1), reason: '$lefts');
    });
  }

  testWidgets('the update bar icon lines up with the row icons below it', (
    tester,
  ) async {
    await _pump(tester, width: 800, installedVersion: '0.1.0');
    final icons = find.byIcon(AppIcons.dock);
    expect(icons, findsNWidgets(2));
    expect(tester.getTopLeft(icons.first).dx, tester.getTopLeft(icons.last).dx);
  });

  testWidgets('installing says so', (tester) async {
    await _pump(tester, width: 800, location: _modulePage);
    await tester.tap(find.text('Install v0.3.1'));
    await tester.pumpAndSettle();
    expect(find.text('Dice installed'), findsOneWidget);
  });
}
