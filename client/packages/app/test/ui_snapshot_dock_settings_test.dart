// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An installed module's Dock page with the generated Settings form (one of
/// each setting type, a stored secret and an unknown type) and the platform
/// access it asks for, at phone and desktop in both themes.
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;
import 'package:slimm_test_support/slimm_test_support.dart';

import 'dock_manifest_fixture.dart';
import 'ui_snapshot_support.dart';

final _installed = {
  'id': 'xp',
  'name': 'xp',
  'version': '1.0.0',
  'artifact_sha256': 'a' * 64,
  'approved_capabilities': <String>['events', 'data.store', 'log.read'],
  'approved_host_capabilities': <String>['events', 'data.store', 'log.read'],
  'extension_points': <Object>[],
  'enabled': true,
  'installed_at': 1000,
  'settings': [
    {'key': 'loud', 'type': 'bool', 'label': 'Level-up posts'},
  ],
};

final _settings = {
  'settings': [
    {
      'key': 'loud',
      'type': 'bool',
      'label': 'Level-up posts',
      'help': 'Announce a level-up in the channel.',
      'value': true,
    },
    {
      'key': 'mode',
      'type': 'choice',
      'label': 'Curve',
      'help': 'How fast levels get harder.',
      'value': 'steady',
      'choices': [
        {'value': 'steady', 'label': 'Steady'},
        {'value': 'steep', 'label': 'Steep'},
      ],
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
    {
      'key': 'cap',
      'type': 'int',
      'label': 'Daily cap',
      'help': 'Most points one member earns a day.',
      'value': 400,
    },
    {
      'key': 'title',
      'type': 'string',
      'label': 'Leaderboard title',
      'value': 'Top talkers',
    },
    {
      'key': 'token',
      'type': 'secret',
      'label': 'Webhook token',
      'help': 'Used to post the weekly summary.',
      'value': {'set': true},
    },
    {'key': 'odd', 'type': 'hologram', 'label': 'Experimental'},
  ],
};

api.SlimmApi _dock(Ref ref) => testApi((request) async {
  final key = request.url.path;
  final Object? body = switch (key) {
    '/space/dock/modules/xp' => dockManifestJson(
      'xp',
      '1.0.0',
      capabilities: ['events', 'data.store', 'log.read'],
      extras: {
        'subscriptions': ['message.created', 'member.joined', 'member.left'],
        'data': {'max_mb': 16},
      },
    ),
    '/space/dock/installed' => [_installed],
    '/space/dock/modules/xp/settings' => _settings,
    _ => null,
  };
  if (body == null) return fixtureResponse(request);
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}, session: ref.watch(sessionProvider));

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in phoneAndDesktop) {
    testWidgets('dock-settings at $viewport fits', (tester) async {
      await renderSurface(
        tester,
        '/settings/dock/xp',
        viewport,
        darkAndLight,
        'dock-settings-$viewport-$darkAndLight',
        overrides: [apiProvider.overrideWith(_dock)],
        settleNestedResolve: true,
        afterSettle: (tester) async {
          await tester.scrollUntilVisible(
            find.textContaining('Experimental'),
            300,
            scrollable: find
                .ancestor(
                  of: find.text('Permissions this will add'),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
        },
      );
    });
  }
}
