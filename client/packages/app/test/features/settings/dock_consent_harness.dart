// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The module page the consent step opens from, shared by the consent tests.
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
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../dock_manifest_fixture.dart';
import '../../ui_snapshot_support.dart';

const consentTokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response consentJson(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> consentInstalledrow(
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
Future<List<Map<String, dynamic>>> consentPump(
  WidgetTester tester, {
  bool community = false,
  List<String> asks = const [],
  String version = '1.0.0',
  String? installedVersion,
  List<String> installedHad = const [],
  Size size = const Size(420, 1400),
  Map<String, dynamic> extras = const {},
  Brightness brightness = Brightness.dark,
}) async {
  final installs = <Map<String, dynamic>>[];
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/space/dock/sources') {
      return consentJson([
        {'id': 'official', 'repo': 'slim-m/modules', 'official': true},
        {'id': 'comm', 'repo': 'someone/mods', 'official': false},
      ]);
    }
    if (path == '/space/dock/modules') {
      return consentJson([
        {'id': 'ladder', 'name': 'ladder', 'version': version, 'summary': 's'},
      ]);
    }
    if (path == '/space/dock/installed') {
      return consentJson([
        if (installedVersion != null)
          consentInstalledrow(installedVersion, installedHad),
      ]);
    }
    if (path == '/space/dock/modules/ladder') {
      return consentJson(
        dockManifestJson('ladder', version, capabilities: asks, extras: extras),
      );
    }
    if (path == '/space/dock/modules/ladder/install') {
      installs.add(jsonDecode(request.body) as Map<String, dynamic>);
      return consentJson(consentInstalledrow(version, asks));
    }
    if (path == '/roles' || path.contains('module-permissions')) {
      return consentJson(<Map<String, dynamic>>[]);
    }
    throw StateError('unexpected ${request.method} $path');
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: consentTokens),
      ),
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
          theme: buildTheme(
            brightness,
            brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
          ),
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
