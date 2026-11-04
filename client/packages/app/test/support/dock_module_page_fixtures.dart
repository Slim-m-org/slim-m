// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Three realistic modules for the module page: a game with no settings, a
/// levels module with settings, badges and profile sections, and one that
/// reaches the network and posts on a timer.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../ui_snapshot_support.dart';

final _sha = 'a' * 64;
final _now = DateTime(2026, 11, 3).millisecondsSinceEpoch;
const _day = 24 * 60 * 60 * 1000;

Map<String, dynamic> _manifest(
  String id,
  String name,
  String summary, {
  required Map<String, dynamic> limits,
  List<Map<String, dynamic>> permissions = const [],
  List<String> capabilities = const [],
  List<Map<String, dynamic>> extensionPoints = const [],
  Map<String, dynamic> extras = const {},
}) => {
  'id': id,
  'name': name,
  'version': '1.2.0',
  'summary': summary,
  'author': 'slim-m',
  'artifact': {
    'kind': 'wasm',
    'path': 'modules/$id/1.2.0/module.wasm',
    'sha256': _sha,
  },
  'runtime': {'backend': 'wasm', 'limits': limits},
  'permissions': permissions,
  'capabilities': capabilities,
  'extension_points': extensionPoints,
  'changelog': [
    {
      'version': '1.2.0',
      'changes': ['Faster start.'],
    },
  ],
  ...extras,
};

Map<String, dynamic> _installed(
  Map<String, dynamic> manifest, {
  List<String> approved = const [],
  Map<String, dynamic> extras = const {},
}) => {
  'id': manifest['id'],
  'name': manifest['name'],
  'version': manifest['version'],
  'artifact_sha256': _sha,
  'approved_capabilities': approved,
  'approved_host_capabilities': approved,
  'extension_points': manifest['extension_points'],
  'enabled': true,
  'installed_at': _now - 30 * _day,
  'fuel_limit': (manifest['runtime'] as Map)['limits']['fuel'],
  'run_stats': [
    {
      'command': 'play',
      'run_count': 289,
      'failure_count': 0,
      'last_run_at': _now - 9 * _day,
      'last_ok_at': _now - 9 * _day,
      'last_duration_ms': 12,
      'max_duration_ms': 40,
      'last_fuel_used': 1200000,
      'max_fuel_used': 2400000,
    },
  ],
  ...extras,
};

final minesweeperManifest = _manifest(
  'minesweeper',
  'Minesweeper',
  'Classic minesweeper anyone in a channel can play.',
  limits: {'memory_mb': 16, 'wall_ms': 1000, 'fuel': 50000000},
  permissions: [
    {
      'key': 'play',
      'name': 'Play Minesweeper',
      'description': 'Start a board.',
    },
  ],
  capabilities: ['data.store'],
  extensionPoints: [
    {
      'kind': 'app',
      'name': 'Minesweeper',
      'description': 'A board the whole channel plays.',
      'command': 'play',
      'permission': 'play',
    },
    {'kind': 'command', 'name': 'play', 'permission': 'play'},
  ],
  extras: {
    'data': {'max_mb': 4},
  },
);

final xpManifest = _manifest(
  'xp',
  'Levels',
  'Members earn points for chatting and talking, and level up.',
  limits: {'memory_mb': 32, 'wall_ms': 2000, 'fuel': 100000000},
  permissions: [
    {'key': 'rank', 'name': 'See ranks', 'description': 'Use /rank.'},
  ],
  capabilities: ['events', 'data.store', 'log.read'],
  extensionPoints: [
    {
      'kind': 'slash-command',
      'name': 'rank',
      'description': 'Shows your level and the top ten.',
      'command': 'rank',
      'permission': 'rank',
    },
    {'kind': 'command', 'name': 'rank', 'permission': 'rank'},
  ],
  extras: {
    'subscriptions': ['message.created', 'member.joined'],
    'data': {'max_mb': 16},
  },
);

final watchManifest = _manifest(
  'watch',
  'Watch party',
  'Posts what is playing on your Jellyfin server.',
  limits: {'memory_mb': 32, 'wall_ms': 5000, 'fuel': 200000000},
  permissions: [
    {'key': 'watch', 'name': 'Start watch parties', 'description': '/watch'},
  ],
  capabilities: ['net.fetch', 'message.post', 'schedule', 'kv.store'],
  extensionPoints: [
    {
      'kind': 'slash-command',
      'name': 'watch',
      'description': 'Start a watch party in your call.',
      'command': 'watch',
      'permission': 'watch',
    },
    {'kind': 'command', 'name': 'watch', 'permission': 'watch'},
  ],
  extras: {
    'network': {
      'hosts': ['jellyfin.home.example'],
      'local': true,
    },
    'schedules': [
      {'command': 'now-playing', 'every_minutes': 5},
    ],
  },
);

final _settingsJson = [
  {'key': 'loud', 'type': 'bool', 'label': 'Level-up posts'},
];

final dockPageModules = <String, Map<String, dynamic>>{
  'minesweeper': minesweeperManifest,
  'xp': xpManifest,
  'watch': watchManifest,
};

final dockPageInstalled = <String, Map<String, dynamic>>{
  'minesweeper': _installed(
    minesweeperManifest,
    approved: ['data.store'],
    extras: {
      'data': {'max_mb': 4},
    },
  ),
  'xp': _installed(
    xpManifest,
    approved: ['events', 'data.store', 'log.read'],
    extras: {
      'subscriptions': ['message.created', 'member.joined'],
      'data': {'max_mb': 16},
      'settings': _settingsJson,
      'slots': [
        {'kind': 'member.badge', 'name': 'level'},
        {'kind': 'profile.section', 'name': 'level'},
      ],
    },
  ),
  'watch': _installed(
    watchManifest,
    approved: ['kv.store', 'message.post', 'net.fetch', 'schedule'],
    extras: {
      'network_hosts': ['jellyfin.home.example'],
      'local_network_approved': true,
      'schedules': [
        {'command': 'now-playing', 'every_minutes': 5},
      ],
      'storage': {
        'entries': 12,
        'bytes': 3400,
        'max_entries': 1000,
        'max_bytes': 1048576,
      },
    },
  ),
};

Map<String, dynamic> _role(String id, String name, {bool everyone = false}) => {
  'id': id,
  'name': name,
  'permissions': 0,
  'is_everyone': everyone,
  'created_at': 1,
};

/// Grants per role id: `everyone` holds every module's keys except xp's.
List<Map<String, dynamic>> _grants(String roleId) => [
  if (roleId == 'r-everyone') ...[
    {'module_id': 'minesweeper', 'perm_key': 'play'},
    {'module_id': 'watch', 'perm_key': 'watch'},
  ],
  if (roleId == 'r-mods') {'module_id': 'xp', 'perm_key': 'rank'},
];

const _settingsValues = {
  'settings': [
    {
      'key': 'loud',
      'type': 'bool',
      'label': 'Level-up posts',
      'help': 'Announce a level-up in the channel.',
      'value': true,
    },
    {
      'key': 'per_minute',
      'type': 'int',
      'label': 'Points per minute',
      'help': 'Earned while in a voice call.',
      'min': 1,
      'max': 20,
      'value': 5,
    },
  ],
};

Object? _answer(http.Request request) {
  final path = request.url.path;
  if (path == '/space/dock/installed') {
    return dockPageInstalled.values.toList();
  }
  if (path == '/space/dock/modules') {
    return [
      for (final m in dockPageModules.values)
        {
          'id': m['id'],
          'name': m['name'],
          'version': m['version'],
          'summary': m['summary'],
        },
    ];
  }
  if (path == '/space/dock/sources') {
    return [
      {'id': 'official', 'repo': 'slim-m/modules', 'official': true},
    ];
  }
  if (path == '/space/dock/modules/xp/settings') return _settingsValues;
  if (path.startsWith('/space/dock/modules/')) {
    return dockPageModules[path.split('/').last];
  }
  if (path == '/roles') {
    return [
      _role('r-everyone', 'everyone', everyone: true),
      _role('r-mods', 'Moderators'),
      _role('r-gamers', 'Gamers'),
    ];
  }
  if (path == '/roles/module-permissions') return <Object>[];
  if (path.startsWith('/roles/') && path.endsWith('/module-permissions')) {
    return _grants(path.split('/')[2]);
  }
  if (path == '/space/settings') {
    return {
      'join_policy': 'invite',
      'module_member_badges': false,
      'module_profile_sections': true,
    };
  }
  return null;
}

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Opens [moduleId]'s page at [size] and returns the requests it sent.
Future<List<http.Request>> pumpDockModulePage(
  WidgetTester tester,
  String moduleId, {
  Size size = const Size(390, 2400),
  Brightness brightness = Brightness.dark,
}) async {
  final sent = <http.Request>[];
  final client = MockClient((request) async {
    sent.add(request);
    final body = _answer(request);
    if (body == null) return http.Response('{"error":"nope"}', 404);
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
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
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            brightness,
            brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
          ),
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) =>
                    DockModuleScreen(moduleId: moduleId),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  return sent;
}
