// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock's three levels, plus Bots and Webhooks, on the snapshot router, with the real screens.
///
/// The router here lists routes by hand, and the two module levels were
/// missing from it, so both surfaces rendered the router's own not-found page
/// and still passed.
library;

import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/admin/bots_screen.dart';
import 'package:slimm_app/src/screens/admin/dock_module_access_screen.dart';
import 'package:slimm_app/src/screens/admin/dock_module_screen.dart';
import 'package:slimm_app/src/screens/admin/dock_screen.dart';
import 'package:slimm_app/src/screens/admin/webhooks_screen.dart';

final dockFixtureRoutes = [
  GoRoute(
    path: Routes.adminBots,
    pageBuilder: (context, state) => modalPage(context, const BotsScreen()),
  ),
  GoRoute(
    path: Routes.adminWebhooks,
    pageBuilder: (context, state) => modalPage(context, const WebhooksScreen()),
  ),
  GoRoute(
    path: Routes.adminDock,
    pageBuilder: (context, state) => modalPage(context, const DockScreen()),
  ),
  GoRoute(
    path: '${Routes.adminDock}/:moduleId',
    pageBuilder: (context, state) => modalPage(
      context,
      DockModuleScreen(moduleId: state.pathParameters['moduleId']!),
    ),
  ),
  GoRoute(
    path: '${Routes.adminDock}/:moduleId/access',
    pageBuilder: (context, state) => modalPage(
      context,
      DockModuleAccessScreen(moduleId: state.pathParameters['moduleId']!),
    ),
  ),
];

final _sha = 'a' * 64;

/// What the fixture server answers under `/space/dock`, or null for every
/// path it has no module data for. One installed, enabled module, so the
/// detail and the access screens show a real state rather than an error.
Object? dockFixtureBody(String path) => switch (path) {
  '/space/dock/modules' => [
    {
      'id': 'code-exec',
      'name': 'Code Blocks',
      'version': '0.3.0',
      'summary': 'Run code snippets in a channel and post the output.',
    },
  ],
  '/space/dock/modules/code-exec' => {
    'id': 'code-exec',
    'name': 'Code Blocks',
    'version': '0.3.0',
    'summary': 'Run code snippets in a channel and post the output.',
    'author': 'slim-m',
    'artifact': {
      'kind': 'wasm',
      'path': 'modules/code-exec/0.3.0/module.wasm',
      'sha256': _sha,
    },
    'runtime': {
      'backend': 'wasm',
      'limits': {'memory_mb': 32, 'wall_ms': 1000, 'fuel': 100000000},
    },
    'permissions': [
      {
        'key': 'run',
        'name': 'Run code',
        'description': 'Run a snippet from a message.',
      },
    ],
    'capabilities': <String>[],
    'extension_points': [
      {'kind': 'code_runner', 'name': 'Code Blocks', 'permission': 'run'},
    ],
  },
  '/space/dock/installed' => [
    {
      'id': 'code-exec',
      'name': 'Code Blocks',
      'version': '0.3.0',
      'artifact_sha256': _sha,
      'approved_capabilities': <String>[],
      'extension_points': <Object>[],
      'enabled': true,
      'installed_at': 1000,
    },
  ],
  _ => null,
};
