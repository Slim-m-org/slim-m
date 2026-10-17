// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A moderator is not offered time out or removal for a member whose granted
/// permissions reach beyond their own: the server refuses both
/// (`escalation_guard`), so the card says so up front instead of after a press.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_moderation_gates.dart';
import 'package:slimm_design_system/design_system.dart';

const _everyone = api.Role(
  id: 'everyone',
  name: 'everyone',
  permissions: Perm.sendMessages,
  isEveryone: true,
  createdAt: 0,
);
const _moderator = api.Role(
  id: 'mod',
  name: 'moderator',
  permissions: Perm.kickMembers | Perm.banMembers | Perm.manageRoles,
  isEveryone: false,
  createdAt: 0,
);
const _admin = api.Role(
  id: 'admin',
  name: 'admin',
  permissions: Perm.administrator,
  isEveryone: false,
  createdAt: 0,
);

const _mine =
    Perm.sendMessages | Perm.kickMembers | Perm.banMembers | Perm.manageRoles;

api.UserProfile _member(List<String> roleIds) => api.UserProfile(
  id: 'm',
  username: 'm',
  displayName: 'M',
  createdAt: 0,
  roleIds: roleIds,
);

Future<MemberModerationGates> _gates(
  WidgetTester tester, {
  required api.UserProfile profile,
  int mine = _mine,
  List<api.Role> roles = const [_everyone, _moderator, _admin],
}) async {
  late MemberModerationGates gates;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        myPermissionsProvider.overrideWithValue(mine),
        rolesProvider.overrideWith((ref) async => roles),
        meProvider.overrideWith((ref) => Completer<api.Me>().future),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Consumer(
          builder: (context, ref, _) {
            ref.watch(rolesProvider);
            gates = memberModerationGates(ref, profile: profile);
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return gates;
}

void main() {
  testWidgets('an administrator target is out of reach for a moderator', (
    tester,
  ) async {
    final gates = await _gates(tester, profile: _member(['admin']));
    expect(gates.outranked, isTrue);
    expect(gates.canTimeOut, isFalse);
    expect(gates.canRemove, isFalse);
    expect(gates.canManageRoles, isTrue);
  });

  testWidgets('a peer or a plain member stays moderatable', (tester) async {
    final peer = await _gates(tester, profile: _member(['mod']));
    expect(peer.outranked, isFalse);
    expect(peer.canTimeOut && peer.canRemove, isTrue);
    final plain = await _gates(tester, profile: _member([]));
    expect(plain.outranked, isFalse);
    expect(plain.canTimeOut && plain.canRemove, isTrue);
  });

  testWidgets('an administrator is never outranked', (tester) async {
    final gates = await _gates(
      tester,
      profile: _member(['admin']),
      mine: _mine | Perm.administrator,
    );
    expect(gates.outranked, isFalse);
    expect(gates.canRemove, isTrue);
  });

  testWidgets('without MANAGE_ROLES nothing is guessed', (tester) async {
    final gates = await _gates(
      tester,
      profile: _member(['admin']),
      mine: Perm.kickMembers | Perm.banMembers,
    );
    expect(gates.outranked, isFalse);
    expect(gates.canTimeOut, isTrue);
  });
}
