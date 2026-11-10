// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A dragged role stays where it was dropped until the refetched roles arrive,
/// rather than snapping back to the old order for a round trip.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/roles_screen.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../members/roles_config_harness.dart';

api.Role _role(String id, String name, {bool everyone = false}) => api.Role(
  id: id,
  name: name,
  permissions: 0,
  isEveryone: everyone,
  createdAt: 0,
  position: 0,
);

/// The nav row comes first in the tree; the open role's detail repeats the name.
double _top(WidgetTester tester, String name) =>
    tester.getTopLeft(find.text(name).first).dy;

void main() {
  testWidgets('a reorder holds its order until the refetched roles land', (
    tester,
  ) async {
    var order = ['a', 'b'];
    Completer<void>? held;
    final h = ConfigHarness(
      handler: (r) => switch ((r.method, r.url.path)) {
        ('PATCH', '/roles/reorder') => () {
          order = ['b', 'a'];
          return jsonOk(<Object>[]);
        }(),
        _ => null,
      },
    );
    await h.pump(
      tester,
      const RolesPane(),
      overrides: [
        myPermissionsProvider.overrideWithValue(Perm.manageRoles),
        rolesProvider.overrideWith((ref) async {
          await held?.future;
          return [
            for (final id in order) _role(id, id == 'a' ? 'Alpha' : 'Beta'),
            _role('e', 'everyone', everyone: true),
          ];
        }),
      ],
    );
    expect(_top(tester, 'Alpha'), lessThan(_top(tester, 'Beta')));
    held = Completer<void>();

    final handle = find.byIcon(AppIcons.dragHandle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(h.writes.single.path, '/roles/reorder');
    expect(
      _top(tester, 'Beta'),
      lessThan(_top(tester, 'Alpha')),
      reason: 'the dropped order stays while the refetch is in flight',
    );

    held.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(_top(tester, 'Beta'), lessThan(_top(tester, 'Alpha')));
  });
}
