// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A fake Dock server with installed modules that are each one update behind,
/// and the Modules pane mounted on it, for the Update all walk's tests.
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
import 'package:slimm_app/src/features/settings/screens/admin/dock_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../dock_manifest_fixture.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const dockUpdateSizes = {
  '390x844': Size(390, 844),
  '1280x800': Size(1280, 800),
};

class DockUpdateMod {
  const DockUpdateMod(
    this.id, {
    this.community = false,
    this.asks = const [],
    this.approvedBefore = const [],
    this.newBuild = false,
    this.refuse = false,
  });

  final String id;

  /// Listed by the community source, so unreviewed.
  final bool community;

  /// What the offered manifest declares.
  final List<String> asks;

  /// What this space approved on the installed build, which also declared it.
  final List<String> approvedBefore;

  /// The offered manifest ships different code than the installed one.
  final bool newBuild;

  /// The install call answers 409.
  final bool refuse;

  String get name => 'Mod $id';
}

final _sha = List.filled(64, 'a').join();
final _oldSha = List.filled(64, 'b').join();

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class DockUpdateWorld {
  DockUpdateWorld(this.mods) {
    for (final m in mods) {
      installed[m.id] = {
        'id': m.id,
        'name': m.name,
        'version': '1.0.0',
        'artifact_sha256': m.newBuild ? _oldSha : _sha,
        'approved_capabilities': m.approvedBefore,
        'approved_host_capabilities': m.approvedBefore,
        'extension_points': <Map<String, dynamic>>[],
        'enabled': true,
        'installed_at': 1000,
        if (m.community) 'source_repo': 'someone/mods',
      };
    }
  }

  final List<DockUpdateMod> mods;
  final installed = <String, Map<String, dynamic>>{};
  final bodies = <Map<String, dynamic>>[];

  List<String> get installs => [for (final b in bodies) b['id'] as String];

  Map<String, dynamic> _entry(DockUpdateMod m) => {
    'id': m.id,
    'name': m.name,
    'version': '2.0.0',
    'summary': 'does something',
  };

  Map<String, dynamic> _install(DockUpdateMod m, Map<String, dynamic> body) {
    final approved =
        (body['approved_host_capabilities'] as List<dynamic>?)
            ?.cast<String>() ??
        [
          for (final c in m.approvedBefore)
            if (m.asks.contains(c) && !(m.newBuild && c == 'message.post')) c,
        ];
    return installed[m.id] = {
      ...installed[m.id]!,
      'version': body['version'],
      'artifact_sha256': _sha,
      'approved_capabilities': m.asks,
      'approved_host_capabilities': approved,
    };
  }

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    final source = request.url.queryParameters['source'];
    if (path == '/space/dock/sources') {
      return _json([
        {'id': 'official', 'repo': 'slim-m/modules', 'official': true},
        {'id': 'comm', 'repo': 'someone/mods', 'official': false},
      ]);
    }
    if (path == '/space/dock/modules') {
      return _json([
        for (final m in mods)
          if (m.community == (source == 'comm')) _entry(m),
      ]);
    }
    if (path == '/space/dock/installed') {
      return _json(installed.values.toList());
    }
    final id = RegExp(
      r'^/space/dock/modules/([^/]+)',
    ).firstMatch(path)?.group(1);
    final mod = mods.where((m) => m.id == id).firstOrNull;
    if (mod == null) {
      throw StateError('unexpected request: ${request.method} ${request.url}');
    }
    if (request.method == 'GET') {
      return _json(
        dockManifestJson(
          mod.id,
          '2.0.0',
          capabilities: mod.asks,
          reviewDigest: 'digest-${mod.id}',
          extras: {'name': mod.name},
        ),
      );
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (mod.refuse) {
      return _json({'error': 'moved on'}, 409);
    }
    bodies.add({...body, 'id': mod.id});
    return _json(_install(mod, body));
  }
}

Future<void> openDockUpdateWorld(
  WidgetTester tester,
  DockUpdateWorld world,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(world.handle),
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
          ],
        ),
      ),
    ),
  );
  await settleDock(tester);
}

Future<void> settleDock(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> tapDock(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await settleDock(tester);
}
