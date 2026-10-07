// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Changing who may use a Dock module: revoking removes every key the module
/// declares, a half-applied change re-reads what the server holds, and
/// turning the module on happens before discovery is asked again.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/slash_command.dart';
import 'package:slimm_app/src/screens/admin/dock_module_access_screen.dart';
import 'package:slimm_app/src/widgets/settings_toggle_row.dart';
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
  'id': 'game-of-life',
  'name': 'Game of Life',
  'version': '0.2.0',
  'summary': 'Conway cellular automata on a channel-sized board.',
};

Map<String, dynamic> _manifest() => {
  ..._entry,
  'artifact': {'kind': 'wasm', 'path': 'm/g.wasm', 'sha256': _sha},
  'runtime': {
    'backend': 'wasm',
    'limits': {'memory_mb': 32, 'wall_ms': 1000, 'fuel': 1000},
  },
  'permissions': [
    {'key': 'play', 'name': 'Play', 'description': 'Seed and step.'},
    {'key': 'edit', 'name': 'Edit', 'description': 'Edit a board.'},
  ],
  'capabilities': <String>[],
  'extension_points': <Map<String, dynamic>>[],
};

Map<String, dynamic> _installed({required bool enabled}) => {
  ..._entry,
  'artifact_sha256': _sha,
  'approved_capabilities': <String>[],
  'extension_points': <Map<String, dynamic>>[],
  'enabled': enabled,
  'installed_at': 1000,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Server {
  _Server({this.enabled = true, this.holdsBoth = false});

  bool enabled;
  bool holdsBoth;
  Completer<void>? enableGate;
  int failDeleteAt = 0;
  final deletes = <String>[];
  int permissionReads = 0;
  final discoveryReads = <bool>[];

  Future<http.Response> handle(http.Request r) async {
    final path = r.url.path;
    if (path == '/space/dock/installed') {
      return _json([_installed(enabled: enabled)]);
    }
    if (path == '/space/dock/modules/game-of-life') return _json(_manifest());
    if (path == '/roles') {
      return _json([
        {
          'id': 'r-mods',
          'name': 'mods',
          'permissions': 0,
          'is_everyone': false,
          'mentionable': false,
          'created_at': 1000,
        },
      ]);
    }
    if (path == '/roles/r-mods/module-permissions' && r.method == 'GET') {
      permissionReads++;
      return _json([
        if (holdsBoth)
          for (final k in ['play', 'edit'])
            {'module_id': 'game-of-life', 'perm_key': k},
      ]);
    }
    if (path.contains('/module-permissions/') && r.method == 'DELETE') {
      deletes.add(path);
      if (deletes.length == failDeleteAt) return _json({'error': 'no'}, 500);
      return http.Response('', 204);
    }
    if (path.contains('/module-permissions/') && r.method == 'PUT') {
      return http.Response('', 204);
    }
    if (path == '/space/dock/modules/game-of-life/enable') {
      await enableGate?.future;
      enabled = true;
      return _json(_installed(enabled: true));
    }
    if (path == '/modules/slash-commands') {
      discoveryReads.add(enabled);
      return _json([
        if (enabled)
          {'module_id': 'game-of-life', 'command': 'life', 'name': 'Life'},
      ]);
    }
    return _json(<Object>[]);
  }
}

Future<ProviderContainer> _open(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(1200, 2400);
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
          httpClient: MockClient(server.handle),
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
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const DockModuleAccessScreen(moduleId: 'game-of-life'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _modsToggle() => find.descendant(
  of: find.byWidgetPredicate(
    (w) =>
        w is SettingsToggleRow && w.semanticLabel == 'Let mods use this module',
  ),
  matching: find.byType(AppToggle),
);

void main() {
  testWidgets('switching a role off revokes every key the module declares', (
    tester,
  ) async {
    final server = _Server(holdsBoth: true);
    await _open(tester, server);
    expect(tester.widget<AppToggle>(_modsToggle()).value, isTrue);

    server.holdsBoth = false;
    await tester.tap(_modsToggle());
    await tester.pumpAndSettle();

    expect(server.deletes, [
      '/roles/r-mods/module-permissions/game-of-life/play',
      '/roles/r-mods/module-permissions/game-of-life/edit',
    ]);
    expect(tester.widget<AppToggle>(_modsToggle()).value, isFalse);
  });

  testWidgets('a revoke that fails halfway re-reads what the server holds', (
    tester,
  ) async {
    final server = _Server(holdsBoth: true)..failDeleteAt = 2;
    await _open(tester, server);
    final readsBefore = server.permissionReads;

    server.holdsBoth = false;
    await tester.tap(_modsToggle());
    await tester.pumpAndSettle();

    expect(server.permissionReads, greaterThan(readsBefore));
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(tester.widget<AppToggle>(_modsToggle()).value, isFalse);
  });

  testWidgets('a grant refetches discovery only once the module is enabled', (
    tester,
  ) async {
    final server = _Server(enabled: false)..enableGate = Completer<void>();
    final container = await _open(tester, server);
    final sub = container.listen(slashCommandProvider, (_, _) {});
    addTearDown(sub.close);
    await tester.pumpAndSettle();
    server.discoveryReads.clear();

    await tester.tap(_modsToggle());
    for (var n = 0; n < 5; n++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    server.enableGate!.complete();
    await tester.pumpAndSettle();

    final cmds = await container.read(slashCommandProvider.future);
    expect(cmds.map((c) => c.command), ['life']);
    expect(server.discoveryReads.last, isTrue);
  });
}
