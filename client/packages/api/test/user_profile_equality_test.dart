// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [UserProfile] needs value equality: a `.select`ed [AuthorResolution]
/// record (see `providers/user_profiles.dart` in the app package) compares
/// its `profile` field with `==`, and a re-resolve after `.clear()` always
/// builds a fresh instance even when nothing about the author actually
/// changed.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

UserProfile _profile({
  List<String> roles = const [],
  List<String> roleIds = const [],
}) =>
    UserProfile(
      id: 'user-1',
      username: 'nick',
      displayName: 'Nick',
      createdAt: 1000,
      avatarUpdatedAt: 2000,
      roles: roles,
      roleIds: roleIds,
      timedOutUntil: 3000,
      statusText: 'away',
    );

void main() {
  group('UserProfile equality', () {
    test('two field-identical instances are == and hash equal', () {
      final a = _profile(roles: const ['Admin'], roleIds: const ['role-1']);
      final b = _profile(roles: const ['Admin'], roleIds: const ['role-1']);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('a scalar field difference breaks equality', () {
      final a = _profile();
      final b = UserProfile(
        id: a.id,
        username: a.username,
        displayName: 'Someone Else',
        createdAt: a.createdAt,
        avatarUpdatedAt: a.avatarUpdatedAt,
        roles: a.roles,
        roleIds: a.roleIds,
        timedOutUntil: a.timedOutUntil,
        statusText: a.statusText,
      );

      expect(a, isNot(equals(b)));
    });

    test('a roles list difference breaks equality', () {
      final a = _profile(roles: const ['Admin'], roleIds: const ['role-1']);
      final b = _profile(roles: const ['Member'], roleIds: const ['role-1']);

      expect(a, isNot(equals(b)));
    });

    test(
        'a roleIds list difference breaks equality even with matching '
        'roles', () {
      final a = _profile(roles: const ['Admin'], roleIds: const ['role-1']);
      final b = _profile(roles: const ['Admin'], roleIds: const ['role-2']);

      expect(a, isNot(equals(b)));
    });

    test('a roles list length difference breaks equality', () {
      final a = _profile(
        roles: const ['Admin'],
        roleIds: const ['role-1'],
      );
      final b = _profile(
        roles: const ['Admin', 'Member'],
        roleIds: const ['role-1', 'role-2'],
      );

      expect(a, isNot(equals(b)));
    });

    test('a role colour change breaks equality, so a name repaints', () {
      UserProfile coloured(int? colour) => UserProfile(
            id: 'user-1',
            username: 'nick',
            displayName: 'Nick',
            createdAt: 1000,
            roles: const ['Admin'],
            roleIds: const ['role-1'],
            roleColors: [colour],
          );

      expect(coloured(3), equals(coloured(3)));
      expect(coloured(3).hashCode, equals(coloured(3).hashCode));
      expect(coloured(3), isNot(equals(coloured(4))));
      expect(coloured(3), isNot(equals(coloured(null))));
    });

    test(
        'each of accountDisplayName, isBot and isWebhook breaks equality alone',
        () {
      UserProfile with_(
              {String? account, bool bot = false, bool hook = false}) =>
          UserProfile(
            id: 'user-1',
            username: 'nick',
            displayName: 'Nick',
            accountDisplayName: account,
            createdAt: 1000,
            isBot: bot,
            isWebhook: hook,
          );

      final base = with_(account: 'Nicholas');
      expect(base, equals(with_(account: 'Nicholas')));
      for (final changed in [
        with_(account: 'Nick C'),
        with_(account: 'Nicholas', bot: true),
        with_(account: 'Nicholas', hook: true),
      ]) {
        expect(base, isNot(equals(changed)));
        expect(base.hashCode, isNot(equals(changed.hashCode)));
      }
    });
  });
}
