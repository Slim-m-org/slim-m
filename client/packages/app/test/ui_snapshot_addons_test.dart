// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Space settings' Addons panes (Modules, a module, Bots, Webhooks) with real
/// rows, at phone and desktop in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts each lays out without overflow.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;

import 'ui_snapshot_support.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _bots = [
  {
    'user_id': 'bot-jelly',
    'username': 'jellyfin',
    'display_name': 'Jellyfin',
    'created_at': 0,
    'token_name': 'Jellyfin',
    'token_last_used_at': 1000,
    'role_id': 'role-1',
    'permissions': 5,
  },
  {
    'user_id': 'bot-new',
    'username': 'greeter',
    'display_name': 'Greeter',
    'created_at': 0,
    'token_name': 'Greeter',
    'token_last_used_at': null,
    'role_id': 'role-2',
    'permissions': 0,
  },
  {
    'user_id': 'bot-old',
    'username': 'old-notifier',
    'display_name': 'Old notifier',
    'created_at': 0,
    'token_name': null,
    'token_last_used_at': 1000,
    'role_id': null,
    'permissions': 0,
  },
];

const _webhooks = [
  {
    'id': 'wh-1',
    'channel_id': 'chan-1',
    'label': 'sonarr',
    'created_at': 0,
    'last_delivery_at': 1,
    'created_by_display_name': 'root',
  },
  {
    'id': 'wh-2',
    'channel_id': 'chan-1',
    'label': 'github releases',
    'created_at': 0,
    'last_delivery_at': null,
    'created_by_display_name': 'root',
  },
];

api.SlimmApi _addons(Ref ref) => testApi((request) async {
  final body = switch (request.url.path) {
    '/bots' => _bots,
    '/webhooks' => _webhooks,
    _ => null,
  };
  if (body == null) return fixtureResponse(request);
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}, session: ref.watch(sessionProvider));

const _routes = {
  'addons-dock': '/settings/dock',
  'addons-module': '/settings/dock/code-exec',
  'addons-bots': '/settings/bots',
  'addons-webhooks': '/settings/webhooks',
};

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const ['dark', 'light']) {
    for (final entry in _routes.entries) {
      for (final viewport in phoneAndDesktop) {
        testWidgets('${entry.key} at $viewport ($theme) fits', (tester) async {
          await renderSurface(
            tester,
            entry.value,
            viewport,
            theme,
            '${entry.key}-$viewport-$theme',
            overrides: [apiProvider.overrideWith(_addons)],
            settleNestedResolve: true,
          );
        });
      }
    }
  }
}
