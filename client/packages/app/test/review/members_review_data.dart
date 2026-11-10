// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roster the members review renders: roles, bots, a long name and an offline member, so no row is a placeholder.
library;

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;

import 'members_review_support.dart';

Map<String, Object?> _member(
  String id,
  String name, {
  List<List<String>> roles = const [],
  bool bot = false,
}) {
  final hoisted = roles.where((r) => _hoistedPositions.containsKey(r[0]));
  return {
    'id': id,
    'username': id.replaceFirst('user-', ''),
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
  _member(
    'user-christoph',
    'Christoph Bartholomew Fitzgerald-Huang III',
    roles: [_helper],
  ),
  _member('user-otto', 'Offline Otto'),
  _member('bot-jelly', 'jellyfin', bot: true),
  _member('bot-greeter', 'greeter', bot: true),
];

const _online = [
  'user-nick',
  'user-ada',
  'user-grace',
  'user-linus',
  'user-sam',
  'user-christoph',
  'bot-jelly',
];

/// Serves the roster and who is online; everything else is the fixture's.
http.Response? reviewRosterReply(http.Request request) {
  final path = request.url.path;
  if (path.endsWith('/members')) return reviewJson(_members);
  if (path == '/presence' && request.method == 'GET') {
    return reviewJson([
      for (final id in _online) {'user_id': id, 'status': 'online'},
    ]);
  }
  return null;
}

/// A member to act on: Ada, with a nickname when [nickname] is given.
api.UserProfile reviewSubject({String? nickname}) => api.UserProfile(
  id: 'user-ada',
  username: 'ada',
  displayName: nickname ?? 'Ada Lovelace',
  accountDisplayName: 'Ada Lovelace',
  nickname: nickname,
  createdAt: 0,
);
