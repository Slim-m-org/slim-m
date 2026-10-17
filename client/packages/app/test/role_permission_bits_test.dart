// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every permission toggle on a role's Permissions tab maps to its own bit:
/// turning one on sends the role's bitmask with exactly that bit added, and
/// turning a held one off sends it with exactly that bit cleared.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/screens/admin/role_permissions_tab.dart';
import 'package:slimm_design_system/design_system.dart';

import 'roles_config_harness.dart';

api.Role _role(int permissions) => api.Role(
  id: 'role-mod',
  name: 'mod',
  permissions: permissions,
  isEveryone: false,
  createdAt: 0,
);

int get _all => Perm.editable.fold(0, (acc, p) => acc | p.$1);

ConfigHarness _server() => ConfigHarness(
  handler: (r) =>
      r.method == 'PATCH' ? jsonOk(roleJson('role-mod', 'mod')) : null,
);

Future<ConfigHarness> _open(
  WidgetTester tester,
  api.Role role, {
  int mine = -1,
  List<api.ModulePermission> catalog = const [],
  List<api.GrantedModulePermission> granted = const [],
}) async {
  final h = _server();
  await h.pump(
    tester,
    RolePermissionsTab(role: role),
    size: const Size(900, 6000),
    overrides: [
      myPermissionsProvider.overrideWithValue(mine == -1 ? _all : mine),
      modulePermissionsProvider.overrideWith((ref) async => catalog),
      roleModulePermissionsProvider(
        role.id,
      ).overrideWith((ref) async => granted),
    ],
  );
  return h;
}

Finder _toggle(String semanticLabel) => find.byWidgetPredicate(
  (w) => w is AppToggle && w.semanticLabel == semanticLabel,
);

Future<void> _saveAndExpectMask(
  WidgetTester tester,
  ConfigHarness h,
  int mask,
) async {
  await tester.tap(find.text('Save changes'));
  await tester.pumpAndSettle();
  final patches = h.writes.where((r) => r.method == 'PATCH').toList();
  expect(patches, hasLength(1));
  expect(patches.single.path, '/roles/role-mod');
  expect(patches.single.body, {'permissions': mask});
}

void main() {
  for (final (bit, label) in Perm.editable) {
    testWidgets('turning on "$label" sends only its bit', (tester) async {
      final h = await _open(tester, _role(0));
      await tester.tap(_toggle(label));
      await tester.pumpAndSettle();
      await _saveAndExpectMask(tester, h, bit);
    });
  }

  testWidgets('turning off a held permission clears only its bit', (
    tester,
  ) async {
    final both = Perm.sendMessages | Perm.manageMessages;
    final h = await _open(tester, _role(both));
    await tester.tap(_toggle('Manage messages'));
    await tester.pumpAndSettle();
    await _saveAndExpectMask(tester, h, Perm.sendMessages);
  });

  testWidgets('several edits go out as one combined mask', (tester) async {
    final h = await _open(tester, _role(Perm.sendMessages));
    await tester.tap(_toggle('Attach files'));
    await tester.tap(_toggle('Send messages'));
    await tester.tap(_toggle('Add reactions'));
    await tester.pumpAndSettle();
    expect(find.text('3 unsaved changes'), findsOneWidget);
    await _saveAndExpectMask(tester, h, Perm.attachFiles | Perm.addReactions);
  });

  testWidgets('toggling a permission back leaves nothing to save', (
    tester,
  ) async {
    await _open(tester, _role(0));
    await tester.tap(_toggle('Attach files'));
    await tester.pumpAndSettle();
    await tester.tap(_toggle('Attach files'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsNothing);
  });

  testWidgets('a permission the caller lacks cannot be turned on', (
    tester,
  ) async {
    final h = await _open(tester, _role(0), mine: Perm.sendMessages);
    await tester.tap(_toggle('Attach files'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsNothing);
    expect(h.writes, isEmpty);
  });

  testWidgets('Administrator is locked unless the caller is one', (
    tester,
  ) async {
    await _open(tester, _role(0), mine: Perm.manageRoles);
    expect(
      tester.widget<AppToggle>(_toggle('Administrator')).onChanged,
      isNull,
    );
  });

  testWidgets('module permissions grant and revoke their own route', (
    tester,
  ) async {
    const catalog = [
      api.ModulePermission(
        moduleId: 'm1',
        moduleName: 'Mod 1',
        permKey: 'grant',
        name: 'Perm grant',
        description: 'd',
      ),
      api.ModulePermission(
        moduleId: 'm1',
        moduleName: 'Mod 1',
        permKey: 'revoke',
        name: 'Perm revoke',
        description: 'd',
      ),
    ];
    final h = await _open(
      tester,
      _role(0),
      catalog: catalog,
      granted: const [
        api.GrantedModulePermission(moduleId: 'm1', permKey: 'revoke'),
      ],
    );
    await tester.tap(_toggle('Perm grant (Mod 1)'));
    await tester.tap(_toggle('Perm revoke (Mod 1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(h.writes.map((r) => '${r.method} ${r.path}').toList(), [
      'PUT /roles/role-mod/module-permissions/m1/grant',
      'DELETE /roles/role-mod/module-permissions/m1/revoke',
    ]);
  });

  testWidgets('a filter that matches nothing says so', (tester) async {
    await _open(tester, _role(0));
    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text('No permissions match'), findsOneWidget);
  });
}
