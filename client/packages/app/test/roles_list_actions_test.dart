// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roles list's two writes: creating a role from the plus, and dragging
/// one role past another to reorder (`@everyone` stays out of the order).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/screens/admin/roles_screen.dart';
import 'package:slimm_design_system/design_system.dart';

import 'roles_config_harness.dart';

api.Role _role(String id, String name, {bool everyone = false}) => api.Role(
  id: id,
  name: name,
  permissions: 0,
  isEveryone: everyone,
  createdAt: 0,
  position: 0,
);

Future<ConfigHarness> _open(WidgetTester tester) async {
  final h = ConfigHarness(
    handler: (r) => switch ((r.method, r.url.path)) {
      ('POST', '/roles') => jsonOk(roleJson('new', 'Crew')),
      ('PATCH', '/roles/reorder') => jsonOk(<Object>[]),
      ('GET', _) => jsonOk(<Object>[]),
      _ => null,
    },
  );
  await h.pump(
    tester,
    const RolesPane(),
    overrides: [
      myPermissionsProvider.overrideWithValue(Perm.manageRoles),
      rolesProvider.overrideWith(
        (ref) async => [
          _role('a', 'Alpha'),
          _role('b', 'Beta'),
          _role('e', 'everyone', everyone: true),
        ],
      ),
    ],
  );
  return h;
}

void main() {
  testWidgets('the plus creates a role from just a name', (tester) async {
    final h = await _open(tester);
    await tester.tap(find.byTooltip(ActionLabels.createRole));
    await tester.pumpAndSettle();

    final create = find.widgetWithText(AppButton, 'Create role');
    expect(tester.widget<AppButton>(create).disabled, isTrue);

    await tester.enterText(find.byType(TextField).last, ' Crew ');
    await tester.pump();
    await tester.tap(create);
    await tester.pumpAndSettle();

    expect(h.writes.single.method, 'POST');
    expect(h.writes.single.path, '/roles');
    expect(h.writes.single.body, {'name': 'Crew', 'permissions': 0});
  });

  testWidgets('dragging a role below another sends the new order', (
    tester,
  ) async {
    final h = await _open(tester);
    final handle = find.byIcon(AppIcons.dragHandle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(h.writes.single.method, 'PATCH');
    expect(h.writes.single.path, '/roles/reorder');
    expect(h.writes.single.body, {
      'role_ids': ['b', 'a'],
    });
  });
}
