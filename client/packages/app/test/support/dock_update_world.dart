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
    this.hosts = const [],
    this.local = false,
    this.localBefore = false,
    this.failAfterInstalls,
    this.dropsOnCarry = const [],
    this.heldHooks = const {},
    this.offeredHooks = const {},
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

  /// The hosts `net.fetch` may reach, on the installed build and the offered one.
  final List<String> hosts;

  /// The offered manifest also asks for the private network.
  final bool local;

  /// This space approved the private network on the installed build.
  final bool localBefore;

  /// After this many installs of the module, the next ones commit and then
  /// answer 500, as a connection that dropped after the server wrote.
  final int? failAfterInstalls;

  /// Access the server withdraws from an install that carries what was
  /// approved, which the client's own carry rules do not foresee.
  final List<String> dropsOnCarry;

  /// The hooks the installed record holds and the offered manifest declares,
  /// each under `interceptors` or `permission_hooks` as the wire names them.
  final Map<String, List<Map<String, dynamic>>> heldHooks;
  final Map<String, List<Map<String, dynamic>>> offeredHooks;

  String get name => 'Mod $id';
}

const _reaskedOnNewBuild = {'message.post', 'net.fetch'};

final _sha = List.filled(64, 'a').join();
final _oldSha = List.filled(64, 'b').join();

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Runs [body] once for each phone and desktop size [dockUpdateSizes] names.
void eachDockUpdateSize(
  String name,
  Future<void> Function(WidgetTester tester, Size size) body,
) {
  for (final MapEntry(key: label, value: size) in dockUpdateSizes.entries) {
    testWidgets('$name ($label)', (tester) => body(tester, size));
  }
}

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
        'network_hosts': m.hosts,
        'local_network_approved': m.localBefore,
        'extension_points': <Map<String, dynamic>>[],
        'enabled': true,
        'installed_at': 1000,
        if (m.community) 'source_repo': 'someone/mods',
        ...m.heldHooks,
      };
    }
  }

  final List<DockUpdateMod> mods;
  final installed = <String, Map<String, dynamic>>{};
  final bodies = <Map<String, dynamic>>[];
  final _committed = <String, int>{};

  /// How many times the installed list was fetched, which the catalog does on every refresh.
  int catalogReads = 0;

  List<String> get installs => [for (final b in bodies) b['id'] as String];

  Map<String, dynamic> _entry(DockUpdateMod m) => {
    'id': m.id,
    'name': m.name,
    'version': '2.0.0',
    'summary': 'does something',
  };

  Map<String, dynamic> _install(DockUpdateMod m, Map<String, dynamic> body) {
    final carried = body['approved_host_capabilities'] == null;
    final approved = carried
        ? [
            for (final c in m.approvedBefore)
              if (m.asks.contains(c) &&
                  !(m.newBuild && _reaskedOnNewBuild.contains(c)) &&
                  !m.dropsOnCarry.contains(c))
                c,
          ]
        : (body['approved_host_capabilities'] as List<dynamic>).cast<String>();
    final local =
        body['approve_local_network'] as bool? ??
        (carried && m.localBefore && approved.contains('net.fetch'));
    return installed[m.id] = {
      ...installed[m.id]!,
      'version': body['version'],
      'artifact_sha256': _sha,
      'approved_capabilities': m.asks,
      'approved_host_capabilities': approved,
      'local_network_approved': local,
      ...m.offeredHooks,
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
      catalogReads++;
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
          network: mod.hosts.isEmpty
              ? null
              : {'hosts': mod.hosts, 'local': mod.local},
          reviewDigest: 'digest-${mod.id}',
          extras: {'name': mod.name, ...mod.offeredHooks},
        ),
      );
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (mod.refuse) {
      return _json({'error': 'moved on'}, 409);
    }
    bodies.add({...body, 'id': mod.id});
    final done = _committed[mod.id] ?? 0;
    _committed[mod.id] = done + 1;
    final answer = _install(mod, body);
    final failAfter = mod.failAfterInstalls;
    if (failAfter != null && done >= failAfter) {
      return _json({'error': 'connection lost'}, 500);
    }
    return _json(answer);
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
