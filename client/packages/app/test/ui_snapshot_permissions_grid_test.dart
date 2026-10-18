// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings with the permissions grid populated: one role column and
/// three members, each holding a mix of allow and deny, at phone and desktop
/// in both themes. Split out so `ui_snapshot_settings_test.dart` keeps its
/// budget.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;

import 'ui_snapshot_support.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

final _overwrites = {
  'overwrites': [
    {
      'kind': 'role',
      'id': 'role-everyone',
      'allow': Perm.viewChannel | Perm.sendMessages,
      'deny': Perm.mentionEveryone,
    },
    {
      'kind': 'member',
      'id': 'user-ada',
      'allow': Perm.attachFiles | Perm.addReactions,
      'deny': 0,
    },
    {
      'kind': 'member',
      'id': 'user-long-name',
      'allow': 0,
      'deny': Perm.sendMessages | Perm.createInvite,
    },
  ],
};

api.SlimmApi _grid(Ref ref) => testApi((request) async {
  final body = switch (request.url.path) {
    '/channels/c-general/overwrites' => _overwrites,
    '/channels/c-general/permissions' => {'permissions': Perm.sendMessages},
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

  for (final theme in const ['dark', 'light']) {
    for (final viewport in phoneAndDesktop) {
      testWidgets('channel-permissions-grid at $viewport ($theme) fits', (
        tester,
      ) async {
        await renderSurface(
          tester,
          '/settings/channel',
          viewport,
          theme,
          'channel-permissions-grid-$viewport-$theme',
          overrides: [apiProvider.overrideWith(_grid)],
        );
      });
    }
  }
}
