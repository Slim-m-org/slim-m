// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Members tab's two writes: adding a searched member to the role, and
/// removing a holder from it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/screens/admin/role_members_tab.dart';

import 'roles_config_harness.dart';

const _role = api.Role(
  id: 'role-mod',
  name: 'mod',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
);

api.UserProfile _member(String id, {bool holds = false}) => api.UserProfile(
  id: id,
  username: id,
  displayName: id,
  createdAt: 0,
  roleIds: holds ? const ['role-mod'] : const [],
);

Future<ConfigHarness> _open(WidgetTester tester) async {
  final h = ConfigHarness();
  await h.pump(
    tester,
    const RoleMembersTab(role: _role),
    overrides: [
      membersProvider.overrideWith(
        (ref) async => [_member('kiki', holds: true), _member('nadia')],
      ),
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
    await tester.tap(find.textContaining('⏎ add'));
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
}
