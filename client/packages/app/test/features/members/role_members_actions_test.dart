// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Members tab's two writes: adding a searched member to the role, and
/// removing a holder from it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_members_tab.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'roles_config_harness.dart';

const _role = api.Role(
  id: 'role-mod',
  name: 'mod',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
);

api.UserProfile _member(String id, {bool holds = false, bool owner = false}) =>
    api.UserProfile(
      id: id,
      username: id,
      displayName: id,
      createdAt: 0,
      isOwner: owner,
      roleIds: holds ? const ['role-mod'] : const [],
    );

/// A moderator ranked above the role, who does not own the Space.
const _moderator = api.Me(
  id: 'self',
  username: 'self',
  displayName: 'self',
  createdAt: 0,
  permissions: Perm.manageRoles,
  topRolePosition: 5,
  reportsRoleLadder: true,
);

Future<ConfigHarness> _open(
  WidgetTester tester, {
  api.Role role = _role,
  List<api.UserProfile>? members,
  api.Me? me,
}) async {
  final h = ConfigHarness();
  await h.pump(
    tester,
    RoleMembersTab(role: role),
    overrides: [
      membersProvider.overrideWith(
        (ref) async =>
            members ?? [_member('kiki', holds: true), _member('nadia')],
      ),
      if (me != null) meProvider.overrideWith((ref) async => me),
    ],
  );
  return h;
}

void main() {
  testWidgets('tapping a search result assigns the role to that member', (
    tester,
  ) async {
    final h = await _open(tester);
    await tester.enterText(find.byType(TextField), 'nad');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Add'));
    await tester.pumpAndSettle();

    expect(h.writes.map((r) => '${r.method} ${r.path}'), [
      'PUT /members/nadia/roles/role-mod',
    ]);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
  });

  testWidgets('submitting the search adds the first match', (tester) async {
    final h = await _open(tester);
    await tester.enterText(find.byType(TextField), 'nad');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(h.writes.single.path, '/members/nadia/roles/role-mod');
  });

  testWidgets('Remove unassigns the role from that holder', (tester) async {
    final h = await _open(tester);
    await tester.tap(find.bySemanticsLabel('Remove kiki'));
    await tester.pumpAndSettle();

    expect(h.writes.map((r) => '${r.method} ${r.path}'), [
      'DELETE /members/kiki/roles/role-mod',
    ]);
  });

  testWidgets('the owner is neither offered to add nor given a Remove', (
    tester,
  ) async {
    await _open(
      tester,
      me: _moderator,
      members: [
        _member('kiki', holds: true),
        _member('olga', holds: true, owner: true),
        _member('olive', owner: true),
        _member('oscar'),
      ],
    );
    expect(find.bySemanticsLabel('Remove kiki'), findsOneWidget);
    expect(find.bySemanticsLabel('Remove olga'), findsNothing);

    await tester.enterText(
      find.widgetWithText(AppInput, 'Search members to add'),
      'o',
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Add kiki'), findsNothing, reason: 'holds it');
    expect(find.bySemanticsLabel('Add oscar'), findsOneWidget);
    expect(find.bySemanticsLabel('Add olive'), findsNothing);
  });

  for (final (name, role) in [
    ('the Bots role', _role.copyWithBots()),
    ('a bot\'s own role', _role.copyWithManager('bot-1')),
  ]) {
    testWidgets('$name follows its bots: no search and no Remove', (
      tester,
    ) async {
      await _open(tester, role: role, me: _moderator);
      expect(find.text('Search members to add'), findsNothing);
      expect(find.bySemanticsLabel('Remove kiki'), findsNothing);
    });
  }
}

extension on api.Role {
  api.Role copyWithBots() => api.Role(
    id: id,
    name: name,
    permissions: permissions,
    isEveryone: false,
    createdAt: 0,
    isBotsRole: true,
  );

  api.Role copyWithManager(String botId) => api.Role(
    id: id,
    name: name,
    permissions: permissions,
    isEveryone: false,
    createdAt: 0,
    managedBotId: botId,
  );
}
