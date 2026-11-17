// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Display tab holds name, colour, mentionable and hoist as one draft
/// behind a single Save bar that sends only what changed; delete asks first.
/// `@everyone` has none of the editable three.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/role_display_tab.dart';
import 'package:slimm_design_system/design_system.dart';

import '../members/roles_config_harness.dart';
import '../../support/async_wait.dart';

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

const _bots = api.Role(
  id: 'role-bots',
  name: 'Bots',
  permissions: 0,
  isEveryone: false,
  isBotsRole: true,
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

    final save = find.widgetWithText(AppButton, 'Save changes');
    expect(save, findsNothing);

    await tester.enterText(find.byType(TextField), '  Moderators ');
    await tester.pump();
    expect(find.text('1 unsaved change'), findsOneWidget);
    expect(h.writes, isEmpty);
    await tester.tap(save);
    await pumpFrames(tester);

    expect(h.writes.map((r) => '${r.method} ${r.path}'), [
      'PATCH /roles/role-mod',
    ]);
    expect(h.writes.single.body, {'name': 'Moderators'});
  });

  testWidgets('the first keystroke keeps the name field focused', (
    tester,
  ) async {
    final h = _server();
    await h.pump(tester, const RoleDisplayTab(role: _mod));
    final field = find.byWidgetPredicate((w) => w is EditableText);

    await tester.tap(field);
    await tester.pump();
    tester.testTextInput.enterText('ModX');
    await tester.pump();

    expect(find.text('1 unsaved change'), findsOneWidget);
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
  });

  testWidgets('submitting the field renames, and a blank name does not', (
    tester,
  ) async {
    final h = _server();
    await h.pump(tester, const RoleDisplayTab(role: _mod));

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester);
    expect(h.writes, isEmpty);

    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField),
      'Crew',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester);
    expect(h.writes.single.body, {'name': 'Crew'});
  });

  testWidgets('the mentionable toggle waits for Save, then sends only it', (
    tester,
  ) async {
    final h = _server();
    await h.pump(tester, const RoleDisplayTab(role: _mod));

    await tester.tap(find.bySemanticsLabel('Anyone can @mention this role'));
    await pumpFrames(tester);
    expect(h.writes, isEmpty);

    await tester.tap(find.widgetWithText(AppButton, 'Save changes'));
    await pumpFrames(tester);

    expect(h.writes.single.method, 'PATCH');
    expect(h.writes.single.body, {'mentionable': true});
  });

  testWidgets('several edits are one Save, and Discard drops them all', (
    tester,
  ) async {
    final h = _server();
    await h.pump(tester, const RoleDisplayTab(role: _mod));

    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField),
      'Crew',
    );
    await tester.tap(find.bySemanticsLabel('Anyone can @mention this role'));
    await tester.tap(find.bySemanticsLabel('Role colour: Teal'));
    await tester.pumpAndSettle();
    expect(find.text('3 unsaved changes'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(find.text('3 unsaved changes'), findsNothing);
    expect(find.text('Save changes'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Crew');
    await tester.tap(find.bySemanticsLabel('Anyone can @mention this role'));
    await tester.tap(find.bySemanticsLabel('Role colour: Teal'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Save changes'));
    await tester.pumpAndSettle();

    expect(h.writes, hasLength(1));
    expect(h.writes.single.body, {
      'name': 'Crew',
      'mentionable': true,
      'color': 9,
    });
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
    expect(find.text('Anyone can @mention this role'), findsNothing);
    expect(find.text('Display role members separately'), findsNothing);
    expect(find.text('Delete role'), findsNothing);
    expect(find.bySemanticsLabel('Role colour: Teal'), findsOneWidget);
  });

  testWidgets('the shared Bots role stays editable but cannot be deleted', (
    tester,
  ) async {
    await _server().pump(tester, const RoleDisplayTab(role: _bots));

    expect(find.byWidgetPredicate((w) => w is TextField), findsOneWidget);
    expect(find.text('Delete role'), findsNothing);
  });
}
