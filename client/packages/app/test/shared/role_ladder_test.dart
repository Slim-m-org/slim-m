// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [RoleLadder] mirrors the server's `http/role_ladder.rs`: a viewer reaches
/// only roles, and moderates only members, strictly below their own highest
/// role; the owner reaches everything and nobody reaches the owner.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/api_failure.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/role_ladder.dart';

api.Role _role(int position, {int permissions = 0, bool bot = false}) =>
    api.Role(
      id: 'r$position',
      name: 'r$position',
      permissions: permissions,
      isEveryone: false,
      createdAt: 0,
      position: position,
      managedBotId: bot ? 'bot' : null,
    );

api.UserProfile _member({int? top, bool owner = false}) => api.UserProfile(
  id: 'maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
  topRolePosition: top,
  isOwner: owner,
);

const _at5 = RoleLadder(permissions: Perm.manageRoles, topPosition: 5);

void main() {
  test('a role reaches only strictly below the viewer\'s highest', () {
    expect(_at5.reachesRole(_role(4)), isTrue);
    expect(_at5.reachesRole(_role(5)), isFalse);
    expect(_at5.reachesRole(_role(6)), isFalse);
    const none = RoleLadder(permissions: Perm.manageRoles);
    expect(none.reachesRole(_role(0)), isFalse, reason: 'holding none');
  });

  test('a member with no role ranks below any role; a tie is refused', () {
    expect(_at5.outranks(_member()), isTrue);
    expect(_at5.outranks(_member(top: 4)), isTrue);
    expect(_at5.outranks(_member(top: 5)), isFalse);
    const none = RoleLadder(permissions: Perm.kickMembers);
    expect(none.outranks(_member()), isFalse);
  });

  test('the owner reaches everyone, and only the owner reaches the owner', () {
    const owner = RoleLadder(permissions: Perm.manageRoles, isOwner: true);
    expect(owner.reachesRole(_role(99)), isTrue);
    expect(owner.outranks(_member(top: 99)), isTrue);
    expect(_at5.outranks(_member(owner: true)), isFalse);
  });

  test(
    'every lock names why, bot roles and the owner\'s held roles included',
    () {
      final member = _member();
      final owner = _member(owner: true);
      expect(_at5.lockOf(_role(1), member: member, held: true), isNull);
      expect(
        _at5.lockOf(_role(1, bot: true), member: member, held: false),
        RoleLock.followsBot,
      );
      expect(
        _at5.lockOf(_role(5), member: member, held: false),
        RoleLock.notBelowYou,
      );
      expect(
        _at5.lockOf(
          _role(1, permissions: Perm.banMembers),
          member: member,
          held: false,
        ),
        RoleLock.missingPermissions,
      );
      expect(
        _at5.lockOf(_role(1), member: owner, held: true),
        RoleLock.memberAboveYou,
      );
      expect(_at5.lockOf(_role(1), member: owner, held: false), isNull);
    },
  );

  test('an older server, or a /me not yet known, ranks nobody', () {
    const older = api.Me(
      id: 'me',
      username: 'me',
      displayName: 'me',
      createdAt: 0,
      permissions: Perm.manageRoles,
    );
    final ladder = RoleLadder.of(older, permissions: Perm.manageRoles);
    expect(ladder.reachesRole(_role(9)), isTrue);
    expect(ladder.outranks(_member(owner: true)), isTrue);
    expect(
      RoleLadder.of(null, permissions: 0).outranks(_member(top: 9)),
      isTrue,
    );
    final current = api.Me.fromJson({
      'id': 'me',
      'username': 'me',
      'display_name': 'me',
      'created_at': 0,
      'permissions': Perm.manageRoles,
      'is_owner': false,
      'top_role_position': 3,
    });
    final ranked = RoleLadder.of(current, permissions: Perm.manageRoles);
    expect(ranked.reachesRole(_role(3)), isFalse);
    expect(ranked.reachesRole(_role(2)), isTrue);
  });

  test('a ladder refusal reads its own reason inline', () {
    final sentence = describeApiFailure(
      'grant "Mods"',
      const api.ForbiddenException(
        'you can only manage roles below your highest role',
        code: api.ForbiddenException.roleLadderCode,
      ),
    );
    expect(
      sentence,
      'Could not grant "Mods": you can only manage roles below your highest '
      'role.',
    );
  });
}
