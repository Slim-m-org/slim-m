// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The docked member pane sectioned by role, with people online and offline
/// and a few bots, at desktop in both themes. The pane only docks where it
/// fits (`LayoutClass.fitsMemberPane`), so there is no phone render of it.
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

Map<String, Object?> _member(
  String id,
  String name, {
  List<List<String>> roles = const [],
  bool bot = false,
}) {
  final hoisted = roles.where((r) => _hoistedPositions.containsKey(r[0]));
  return {
    'id': id,
    'username': id,
    'display_name': name,
    'created_at': 0,
    'is_bot': bot,
    'role_ids': [for (final r in roles) r[0]],
    'roles': [for (final r in roles) r[1]],
    'hoisted_role_id': hoisted.firstOrNull?[0],
    'hoisted_role_position': hoisted.isEmpty
        ? null
        : _hoistedPositions[hoisted.first[0]],
  };
}

// Helper is deliberately not hoisted, so it never gets a heading.
const _hoistedPositions = {'r-admin': 9, 'r-mod': 5};

const _admin = ['r-admin', 'Admin'];
const _mod = ['r-mod', 'Moderator'];
const _helper = ['r-helper', 'Helper'];

final _members = [
  _member('user-nick', 'Nick', roles: [_admin]),
  _member('user-ada', 'Ada Lovelace', roles: [_admin, _mod]),
  _member('user-grace', 'Grace Hopper', roles: [_mod, _helper]),
  _member('user-linus', 'Linus', roles: [_helper]),
  _member('user-sam', 'Sam'),
  _member('user-ren', 'Ren', roles: [_mod]),
  _member('user-off', 'Offline Otto'),
  _member('bot-jelly', 'jellyfin', bot: true),
  _member('bot-greeter', 'greeter', bot: true),
];

const _online = [
  'user-nick',
  'user-ada',
  'user-grace',
  'user-linus',
  'user-sam',
  'bot-jelly',
];

api.SlimmApi _roster(Ref ref) => testApi((request) async {
  final path = request.url.path;
  final Object? body = path.endsWith('/members')
      ? _members
      : path == '/presence' && request.method == 'GET'
      ? [
          for (final id in _online) {'user_id': id, 'status': 'online'},
        ]
      : null;
  if (body == null) return fixtureResponse(request);
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}, session: ref.watch(sessionProvider));

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const [darkAndLight]) {
    testWidgets('member-roster-roles at desktop ($theme) fits', (tester) async {
      await renderSurface(
        tester,
        '/channels/c-general',
        'desktop',
        theme,
        'member-roster-roles-desktop-$theme',
        overrides: [apiProvider.overrideWith(_roster)],
      );
    });
  }
}
