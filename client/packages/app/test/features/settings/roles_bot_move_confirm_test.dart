// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A drop that puts a bot's role above a role it sat below asks first, since
/// the bot then manages that role and its members; a drop that gives a bot no
/// new reach goes straight through.
library;

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

/// The bot's role on top, over a person's role.
const _botOnTop = [
  api.Role(
    id: 'b',
    name: 'ci-bot',
    permissions: 0,
    isEveryone: false,
    createdAt: 0,
    position: 2,
    managedBotId: 'bot-1',
  ),
  api.Role(
    id: 'a',
    name: 'Alpha',
    permissions: 0,
    isEveryone: false,
    createdAt: 0,
    position: 1,
  ),
  api.Role(
    id: 'e',
    name: 'everyone',
    permissions: 0,
    isEveryone: true,
    createdAt: 0,
  ),
];

Future<ConfigHarness> _pump(
  WidgetTester tester, {
  List<api.Role> roles = _roles,
}) async {
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
      rolesProvider.overrideWith((ref) async => roles),
    ],
  );
  return h;
}

/// Drags the first role's handle down past the second, or the last's up past the one above.
Future<void> _drag(WidgetTester tester, {required bool down}) async {
  final handles = find.byIcon(AppIcons.dragHandle);
  final handle = down ? handles.first : handles.last;
  final step = down ? 1.0 : -1.0;
  final gesture = await tester.startGesture(tester.getCenter(handle));
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(Offset(0, 20 * step));
  await tester.pump();
  await gesture.moveBy(Offset(0, 60 * step));
  await tester.pump();
  await gesture.up();
  await pumpFrames(tester, frames: 25);
}

Future<void> _dragBotUp(WidgetTester tester) => _drag(tester, down: false);

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

  testWidgets('moving a person\'s role down below a bot role asks too', (
    tester,
  ) async {
    final h = await _pump(tester);

    await _drag(tester, down: true);
    expect(find.text('Move Alpha below ci-bot?'), findsOneWidget);
    expect(h.writes, isEmpty);

    await tester.tap(find.text('Move down'));
    await pumpFrames(tester, frames: 25);
    expect(h.writes.single.path, '/roles/reorder');
  });

  testWidgets('a move that only takes reach from a bot goes straight through', (
    tester,
  ) async {
    final h = await _pump(tester, roles: _botOnTop);

    await _drag(tester, down: false);
    expect(find.text('Cancel'), findsNothing, reason: 'no confirm opened');
    expect(h.writes.single.path, '/roles/reorder');
  });
}
