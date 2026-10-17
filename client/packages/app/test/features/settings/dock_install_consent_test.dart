// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The consent step before a module is installed or updated
/// (docs/decisions/0067-module-install-consent.md): an unverified module with
/// capabilities needs an explicit acknowledgement, a verified one does not,
/// and an update only asks again when it wants access the install lacked.
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
import 'package:slimm_app/src/features/settings/screens/admin/dock_install_consent.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_row.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../dock_manifest_fixture.dart';
import '../../ui_snapshot_support.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _installedRow(
  String version,
  List<String> hadCapabilities,
) => {
  'id': 'ladder',
  'name': 'ladder',
  'version': version,
  'artifact_sha256': dockManifestJson('ladder', version)['artifact']['sha256'],
  'approved_capabilities': hadCapabilities,
  'extension_points': <Map<String, dynamic>>[],
  'enabled': true,
  'installed_at': 1000,
};

/// Opens the module page from the official source, or the community one when
/// [community]; returns the install bodies sent.
Future<List<Map<String, dynamic>>> _pump(
  WidgetTester tester, {
  bool community = false,
  List<String> asks = const [],
  String version = '1.0.0',
  String? installedVersion,
  List<String> installedHad = const [],
  Size size = const Size(420, 1400),
}) async {
  final installs = <Map<String, dynamic>>[];
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/space/dock/sources') {
      return _json([
        {'id': 'official', 'repo': 'slim-m/modules', 'official': true},
        {'id': 'comm', 'repo': 'someone/mods', 'official': false},
      ]);
    }
    if (path == '/space/dock/modules') {
      return _json([
        {'id': 'ladder', 'name': 'ladder', 'version': version, 'summary': 's'},
      ]);
    }
    if (path == '/space/dock/installed') {
      return _json([
        if (installedVersion != null)
          _installedRow(installedVersion, installedHad),
      ]);
    }
    if (path == '/space/dock/modules/ladder') {
      return _json(dockManifestJson('ladder', version, capabilities: asks));
    }
    if (path == '/space/dock/modules/ladder/install') {
      installs.add(jsonDecode(request.body) as Map<String, dynamic>);
      return _json(_installedRow(version, asks));
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
  // The view, not just the surface: layout reads MediaQuery, which follows the view.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => DockModuleScreen(
                  moduleId: 'ladder',
                  source: community ? 'comm' : null,
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

Finder _pageButton(String label) => find.text(label);

bool _sheetButtonDisabled(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label)).disabled;

Finder get _verifiedBadge => find.byType(DockVerifiedBadge);

void main() {
  testWidgets('unverified with access: Install waits for the acknowledgement', (
    tester,
  ) async {
    final installs = await _pump(
      tester,
      community: true,
      asks: ['kv.store', 'message.post'],
    );
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not verified'), findsOneWidget);
    expect(_sheetButtonDisabled(tester, 'Install'), isTrue);
    expect(installs, isEmpty);

    await writeSnapshot(tester, 'dock-consent-unverified-phone');
    await tester.tap(find.text('I understand what this module can do'));
    await tester.pumpAndSettle();
    expect(_sheetButtonDisabled(tester, 'Install'), isFalse);
    await tester.tap(find.widgetWithText(AppButton, 'Install'));
    await tester.pumpAndSettle();
    expect(installs, hasLength(1));
  });

  testWidgets('the sheet lists each requested capability sentence', (
    tester,
  ) async {
    await _pump(tester, community: true, asks: ['kv.store', 'message.post']);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    expect(
      find.text('Can keep its own private data on your server.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Can post messages in your space as whoever runs it, marked as '
        'this module.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Each run is limited to 32 MB'), findsOneWidget);
  });

  testWidgets('verified with access: Install is enabled straight away', (
    tester,
  ) async {
    final installs = await _pump(tester, asks: ['message.post']);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();

    expect(find.text('I understand what this module can do'), findsNothing);
    expect(find.textContaining('Not verified'), findsNothing);
    expect(_sheetButtonDisabled(tester, 'Install'), isFalse);
    await writeSnapshot(tester, 'dock-consent-verified-phone');
    await tester.tap(find.widgetWithText(AppButton, 'Install'));
    await tester.pumpAndSettle();
    expect(installs, hasLength(1));
  });

  testWidgets('cancelling installs nothing', (tester) async {
    final installs = await _pump(tester, community: true, asks: ['kv.store']);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(installs, isEmpty);
    expect(find.text('Install v1.0.0'), findsOneWidget);
  });

  testWidgets('unverified without access gets a line but no checkbox', (
    tester,
  ) async {
    await _pump(tester, community: true);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not verified'), findsOneWidget);
    expect(
      find.text('It runs code on your server with no access to your space.'),
      findsOneWidget,
    );
    expect(find.text('I understand what this module can do'), findsNothing);
    expect(_sheetButtonDisabled(tester, 'Install'), isFalse);
  });

  testWidgets('verified without access installs with no consent step', (
    tester,
  ) async {
    final installs = await _pump(tester);
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    expect(installs, hasLength(1));
  });

  testWidgets('an update asking for new access shows the consent step', (
    tester,
  ) async {
    final installs = await _pump(
      tester,
      community: true,
      version: '2.0.0',
      installedVersion: '1.0.0',
      installedHad: ['kv.store'],
      asks: ['kv.store', 'message.post'],
    );
    await tester.tap(_pageButton('Update to v2.0.0'));
    await tester.pumpAndSettle();

    expect(find.text('This version asks for new access. It can:'), findsOne);
    expect(find.textContaining('post messages'), findsOneWidget);
    expect(
      find.textContaining('keep its own private data'),
      findsNothing,
      reason: 'only what is new is asked about',
    );
    expect(_sheetButtonDisabled(tester, 'Update'), isTrue);
    expect(installs, isEmpty);
  });

  testWidgets('an update asking for nothing new goes straight through', (
    tester,
  ) async {
    final installs = await _pump(
      tester,
      community: true,
      version: '2.0.0',
      installedVersion: '1.0.0',
      installedHad: ['kv.store'],
      asks: ['kv.store'],
    );
    await tester.tap(_pageButton('Update to v2.0.0'));
    await tester.pumpAndSettle();
    expect(installs, hasLength(1));
  });

  testWidgets('the Verified badge shows on official modules only', (
    tester,
  ) async {
    await _pump(tester);
    expect(_verifiedBadge, findsOneWidget);
  });

  testWidgets('a community module has no Verified badge', (tester) async {
    await _pump(tester, community: true);
    expect(_verifiedBadge, findsNothing);
  });

  testWidgets('the Dock list marks official rows and not community ones', (
    tester,
  ) async {
    const entry = api.DockIndexEntry(
      id: 'ladder',
      name: 'ladder',
      version: '1.0.0',
      summary: 's',
    );
    for (final source in [null, 'comm']) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: DockModuleRow(entry: entry, installed: null, source: source),
          ),
        ),
      );
      expect(_verifiedBadge, source == null ? findsOneWidget : findsNothing);
    }
  });

  testWidgets('the row marks Verified with an icon, not a chip', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);
    expect(find.text('VERIFIED'), findsNothing);
    expect(find.byTooltip('Verified'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Verified')), findsWidgets);
    semantics.dispose();
  });

  testWidgets('the consent sheet at desktop width', (tester) async {
    await _pump(
      tester,
      community: true,
      asks: ['kv.store', 'message.post'],
      size: const Size(1100, 900),
    );
    await tester.tap(_pageButton('Install v1.0.0'));
    await tester.pumpAndSettle();
    await writeSnapshot(tester, 'dock-consent-unverified-desktop');
  });
}
