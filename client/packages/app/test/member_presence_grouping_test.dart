// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the member pane decides who is "online". `isReachablePresence` and
/// `groupRoster` carry two product rules with no test: hidden is
/// the "appear offline" state and must group as offline, and a member whose
/// presence is unknown counts as offline rather than being assumed online -
/// the only honest default. The two lists are also name-sorted.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/roster_grouping.dart';
import 'package:slimm_design_system/design_system.dart' show AppPresence;

api.UserProfile _m(String id, String displayName, {bool isBot = false}) =>
    api.UserProfile(
      isBot: isBot,
      id: id,
      username: id,
      displayName: displayName,
      createdAt: 0,
    );

void main() {
  roleGroupingTests();
  group('isReachablePresence', () {
    test('online, away and dnd count as reachable', () {
      for (final s in [AppPresence.online, AppPresence.away, AppPresence.dnd]) {
        expect(isReachablePresence(s), isTrue, reason: '$s');
      }
    });

    test('offline and hidden do not', () {
      expect(isReachablePresence(AppPresence.offline), isFalse);
      expect(isReachablePresence(AppPresence.hidden), isFalse);
    });
  });

  group('groupRoster', () {
    test('splits reachable from the rest, hidden and unknown both offline', () {
      final members = [
        _m('a', 'Ana'),
        _m('b', 'Bo'),
        _m('c', 'Cara'),
        _m('d', 'Del'),
      ];
      final grouped = groupRoster(members, {
        'a': AppPresence.online,
        'b': AppPresence.hidden, // appears offline
        'c': AppPresence.dnd,
        // 'd' is absent: unknown, so offline
      });

      expect(grouped.online.map((m) => m.id), ['a', 'c']);
      expect(grouped.offline.map((m) => m.id), ['b', 'd']);
    });

    test('each group is sorted by display name, case-insensitively', () {
      final members = [_m('b1', 'Banana'), _m('a1', 'apple')];
      final grouped = groupRoster(members, {
        'b1': AppPresence.online,
        'a1': AppPresence.online,
      });

      expect(grouped.online.map((m) => m.id), [
        'a1',
        'b1',
      ], reason: 'apple sorts before Banana only when case is folded');
    });
  });

  test(
    'a bot lands in its own group whatever its presence, never in online or offline',
    () {
      final grouped = groupRoster(
        [
          _m('a', 'Ana'),
          _m('z', 'Zed bot', isBot: true),
          _m('b', 'Bo bot', isBot: true),
        ],
        {'a': AppPresence.online, 'z': AppPresence.online},
      );
      expect(grouped.online.map((m) => m.id), ['a']);
      expect(grouped.offline, isEmpty);
      expect(grouped.bots.map((m) => m.id), ['b', 'z']);
    },
  );

  test('rosterEntries puts the Bots group after Offline', () {
    final entries = rosterEntries(
      RosterGroups(
        online: [_m('a', 'Ada')],
        offline: [_m('b', 'Bo')],
        bots: [_m('r', 'Roles', isBot: true)],
      ),
    );
    expect((entries.last as RosterMember).profile.id, 'r');
    expect(
      (entries[entries.length - 2] as RosterGroupLabel).text,
      'Bots \u00b7 1',
    );
  });

  group('rosterEntries', () {
    test('each non-empty group is its counted heading then its members', () {
      final entries = rosterEntries(
        RosterGroups(
          online: [_m('a', 'Ada')],
          offline: [_m('b', 'Bo'), _m('c', 'Cy')],
          bots: const [],
        ),
      );
      expect(entries, hasLength(5));
      expect((entries[0] as RosterGroupLabel).text, 'Online \u00b7 1');
      expect((entries[1] as RosterMember).profile.id, 'a');
      expect((entries[2] as RosterGroupLabel).text, 'Offline \u00b7 2');
      expect((entries[3] as RosterMember).profile.id, 'b');
      expect((entries[4] as RosterMember).profile.id, 'c');
    });

    test('an empty group contributes no heading', () {
      final entries = rosterEntries(
        RosterGroups(
          online: const [],
          offline: [_m('b', 'Bo')],
          bots: const [],
        ),
      );
      expect(entries, hasLength(2));
      expect((entries[0] as RosterGroupLabel).text, startsWith('Offline'));
    });
  });
}

/// A member holding [roles] (highest first), listed under [hoisted], a role
/// of theirs paired with its position, when one is given.
api.UserProfile _r(
  String id,
  String name,
  List<(String, String)> roles, {
  (String, String)? hoisted,
  int position = 0,
  bool isBot = false,
}) => api.UserProfile(
  isBot: isBot,
  id: id,
  username: id,
  displayName: name,
  createdAt: 0,
  roleIds: [for (final r in roles) r.$1],
  roles: [for (final r in roles) r.$2],
  hoistedRoleId: hoisted?.$1,
  hoistedRolePosition: hoisted == null ? null : position,
);

void roleGroupingTests() {
  const admin = ('r-admin', 'Admin');
  const mod = ('r-mod', 'Mod');
  const vip = ('r-vip', 'VIP');
  final allOnline = {
    for (final id in ['a', 'm', 'v', 'p', 'o', 'b']) id: AppPresence.online,
  };

  group('role sections', () {
    test('sections follow hoisted role position, highest first', () {
      final grouped = groupRoster([
        _r('v', 'Vera', [vip], hoisted: vip, position: 1),
        _r('m', 'Max', [mod, vip], hoisted: mod, position: 5),
        _r('a', 'Ada', [admin, mod], hoisted: admin, position: 9),
        _r('p', 'Pat', const []),
      ], allOnline);
      expect(grouped.roles.map((s) => s.name), ['Admin', 'Mod', 'VIP']);
      expect(grouped.roles[1].members.single.id, 'm');
      expect(grouped.online.map((m) => m.id), ['p']);
    });

    test('a role held but not hoisted makes no section', () {
      final grouped = groupRoster([
        _r('a', 'Ada', [admin, mod], hoisted: mod, position: 5),
        _r('v', 'Vera', [vip]),
      ], allOnline);
      expect(grouped.roles.map((s) => s.name), ['Mod']);
      expect(grouped.online.map((m) => m.id), ['v']);
    });

    test('a member lands under the hoisted role, not their top role', () {
      final grouped = groupRoster([
        _r('a', 'Ada', [admin, mod], hoisted: mod, position: 5),
      ], allOnline);
      expect(grouped.roles.single.roleId, 'r-mod');
      expect(grouped.online, isEmpty);
    });

    test('an offline holder of a hoisted role goes to Offline', () {
      final grouped = groupRoster(
        [
          _r('a', 'Ada', [admin], hoisted: admin, position: 9),
          _r('m', 'Max', [mod], hoisted: mod, position: 5),
        ],
        {'a': AppPresence.online},
      );
      expect(grouped.roles.map((s) => s.name), ['Admin']);
      expect(grouped.offline.single.id, 'm');
    });

    test('a bot with a hoisted role stays in Bots', () {
      final grouped = groupRoster([
        _r('b', 'Botty', [admin], hoisted: admin, position: 9, isBot: true),
      ], allOnline);
      expect(grouped.roles, isEmpty);
      expect(grouped.bots.single.id, 'b');
    });

    test('roles at one position are ordered by name', () {
      final grouped = groupRoster([
        _r('m', 'Max', [mod], hoisted: mod),
        _r('v', 'Vera', [vip], hoisted: vip),
        _r('a', 'Ada', [admin], hoisted: admin),
      ], allOnline);
      expect(grouped.roles.map((s) => s.name), ['Admin', 'Mod', 'VIP']);
    });

    test('a hoisted role beyond the member\'s own roles gives no section', () {
      final member = api.UserProfile(
        id: 'p',
        username: 'p',
        displayName: 'Pat',
        createdAt: 0,
        roleIds: const ['r-x'],
        roles: const ['X'],
        hoistedRoleId: 'r-other',
        hoistedRolePosition: 3,
      );
      expect(groupRoster([member], allOnline).roles, isEmpty);
    });
  });

  test('rosterEntries orders roles, Online, Offline, Bots', () {
    final grouped = groupRoster(
      [
        _r('b', 'Botty', [admin], hoisted: admin, position: 9, isBot: true),
        _r('o', 'Off', const []),
        _r('p', 'Pat', const []),
        _r('a', 'Ada', [admin], hoisted: admin, position: 9),
      ],
      {'a': AppPresence.online, 'p': AppPresence.online},
    );
    final labels = [
      for (final e in rosterEntries(grouped))
        if (e is RosterGroupLabel) e.text,
    ];
    expect(labels, ['Admin · 1', 'Online · 1', 'Offline · 1', 'Bots · 1']);
  });
}
