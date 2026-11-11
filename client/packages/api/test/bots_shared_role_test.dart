// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot granted nothing has no managed role, and the shared Bots role is marked.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('a bot with no managed role reads back with a null role id', () {
    final bot = Bot.fromJson(const {
      'user_id': 'b1',
      'username': 'helper',
      'display_name': 'helper',
      'created_at': 1,
      'role_id': null,
      'permissions': 0,
    });
    expect(bot.roleId, isNull);
    expect(bot.permissions, 0);
  });

  test('the Bots role is marked, and a role from an older server is not', () {
    const base = {
      'id': 'r1',
      'name': 'Bots',
      'permissions': 0,
      'is_everyone': false,
      'created_at': 1,
    };
    expect(Role.fromJson({...base, 'is_bots_role': true}).isBotsRole, isTrue);
    expect(Role.fromJson(base).isBotsRole, isFalse);
  });
}
