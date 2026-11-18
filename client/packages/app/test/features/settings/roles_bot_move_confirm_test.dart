// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Dragging a bot's role up the ladder asks first, since the bot then manages
/// more; a person's role and a move down go straight through.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/roles_screen.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../members/roles_config_harness.dart';

const _roles = [
  api.Role(
    id: 'a',
    name: 'Alpha',
    permissions: 0,
    isEveryone: false,
    createdAt: 0,
    position: 2,
  ),
  api.Role(
    id: 'b',
    name: 'ci-bot',
    permissions: 0,
    isEveryone: false,
    createdAt: 0,
    position: 1,
    managedBotId: 'bot-1',
  ),
  api.Role(
    id: 'e',
    name: 'everyone',
    permissions: 0,
    isEveryone: true,
    createdAt: 0,
  ),
];

Future<ConfigHarness> _pump(WidgetTester tester) async {
  final h = ConfigHarness(
    handler: (r) => switch ((r.method, r.url.path)) {
      ('PATCH', '/roles/reorder') => jsonOk(<Object>[]),
      _ => null,
    },
  );
  await h.pump(
    tester,
    const RolesPane(),
    overrides: [
      myPermissionsProvider.overrideWithValue(Perm.manageRoles),
      rolesProvider.overrideWith((ref) async => _roles),
    ],
  );
  return h;
}

Future<void> _dragBotUp(WidgetTester tester) async {
  final handle = find.byIcon(AppIcons.dragHandle).last;
  final gesture = await tester.startGesture(tester.getCenter(handle));
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20));
  await tester.pump();
  await gesture.moveBy(const Offset(0, -60));
  await tester.pump();
  await gesture.up();
  await pumpFrames(tester, frames: 25);
}

void main() {
  testWidgets('moving a bot role up asks, and Cancel leaves it', (
    tester,
  ) async {
    final h = await _pump(tester);

    await _dragBotUp(tester);
    expect(find.text('Move ci-bot up?'), findsOneWidget);
    expect(h.writes, isEmpty);

    await tester.tap(find.text('Cancel'));
    await pumpFrames(tester, frames: 25);
    expect(h.writes, isEmpty);
  });

  testWidgets('confirming the move saves the new order', (tester) async {
    final h = await _pump(tester);

    await _dragBotUp(tester);
    await tester.tap(find.text('Move up'));
    await pumpFrames(tester, frames: 25);

    expect(h.writes.single.path, '/roles/reorder');
  });
}
