// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every control on a role's Display tab sends exactly its own change:
/// rename, mentionable and delete here; colour and hoist have their own
/// files. `@everyone` has none of the three.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/admin/role_display_tab.dart';
import 'package:slimm_design_system/design_system.dart';

import 'roles_config_harness.dart';

const _mod = api.Role(
  id: 'role-mod',
  name: 'Mod',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
);

const _everyone = api.Role(
  id: 'role-everyone',
  name: 'everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

ConfigHarness _server() => ConfigHarness(
  handler: (r) => r.method == 'PATCH'
      ? jsonOk(roleJson('role-mod', 'Mod'))
      : r.method == 'GET'
      ? jsonOk(<Object>[])
      : null,
);

void main() {
  testWidgets('rename sends the trimmed name only once it differs', (
    tester,
  ) async {
    final h = _server();
    await h.pump(tester, const RoleDisplayTab(role: _mod));

    final save = find.widgetWithText(AppButton, 'Save name');
    expect(tester.widget<AppButton>(save).disabled, isTrue);

    await tester.enterText(find.byType(TextField), '  Moderators ');
    await tester.pump();
    expect(tester.widget<AppButton>(save).disabled, isFalse);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(h.writes.map((r) => '${r.method} ${r.path}'), [
      'PATCH /roles/role-mod',
    ]);
    expect(h.writes.single.body, {'name': 'Moderators'});
  });

  testWidgets('submitting the field renames, and a blank name does not', (
    tester,
  ) async {
    final h = _server();
    await h.pump(tester, const RoleDisplayTab(role: _mod));

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(h.writes, isEmpty);

    await tester.enterText(find.byType(TextField), 'Crew');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(h.writes.single.body, {'name': 'Crew'});
  });

  testWidgets('the mentionable toggle sends mentionable and nothing else', (
    tester,
  ) async {
    final h = _server();
    await h.pump(tester, const RoleDisplayTab(role: _mod));

    await tester.tap(find.bySemanticsLabel('Anyone can @mention this role'));
    await tester.pumpAndSettle();

    expect(h.writes.single.method, 'PATCH');
    expect(h.writes.single.body, {'mentionable': true});
  });

  testWidgets('delete asks first, then deletes the role', (tester) async {
    final h = _server();
    await h.pump(tester, const RoleDisplayTab(role: _mod));

    await tester.ensureVisible(find.text('Delete role'));
    await tester.tap(find.text('Delete role'));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Mod"?'), findsOneWidget);
    expect(h.writes, isEmpty);

    await tester.tap(find.widgetWithText(AppButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(h.writes.map((r) => '${r.method} ${r.path}'), [
      'DELETE /roles/role-mod',
    ]);
  });

  testWidgets('cancelling the delete confirmation sends nothing', (
    tester,
  ) async {
    final h = _server();
    await h.pump(tester, const RoleDisplayTab(role: _mod));

    await tester.ensureVisible(find.text('Delete role'));
    await tester.tap(find.text('Delete role'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.writes, isEmpty);
  });

  testWidgets('@everyone has no rename, mention, member-list or delete', (
    tester,
  ) async {
    await _server().pump(tester, const RoleDisplayTab(role: _everyone));

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Save name'), findsNothing);
    expect(find.text('Anyone can @mention this role'), findsNothing);
    expect(find.text('Display role members separately'), findsNothing);
    expect(find.text('Delete role'), findsNothing);
    expect(find.bySemanticsLabel('Role colour: Teal'), findsOneWidget);
  });
}
