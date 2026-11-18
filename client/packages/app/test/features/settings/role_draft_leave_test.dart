// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A role's unsaved Display or Permissions edits are never dropped unasked:
/// closing settings, another tab, or the phone's back asks first. Closing with
/// "Display role members separately" switched on but unsaved used to lose it
/// silently, so the member list never changed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/role_preview/providers/role_preview_controller.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_detail.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_sub_pages.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/role_ladder.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../members/roles_config_harness.dart';

const _role = api.Role(
  id: 'role-crew',
  name: 'crew',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
  position: 1,
);

final _ladder = roleLadderProvider.overrideWithValue(
  const RoleLadder(permissions: Perm.manageRoles, topPosition: 5),
);

Finder get _hoistSwitch => find.descendant(
  of: find.ancestor(
    of: find.text('Display role members separately'),
    matching: find.byWidgetPredicate((w) => w is Row),
  ),
  matching: find.byWidgetPredicate((w) => w is AppToggle),
);

Future<void> _toggleHoist(WidgetTester tester) async {
  await tester.tap(find.text('Display'));
  await pumpFrames(tester);
  await tester.ensureVisible(_hoistSwitch);
  await tester.tap(_hoistSwitch);
  await pumpFrames(tester);
}

/// [home] under a real router at [start], beside the channels and roles routes it can leave for.
Widget _routed(String start, Widget home) => MaterialApp.router(
  theme: buildTheme(Brightness.light, AppTokens.light),
  routerConfig: GoRouter(
    initialLocation: start,
    routes: [
      GoRoute(
        path: start,
        builder: (_, _) => Scaffold(body: home),
      ),
      GoRoute(path: Routes.channels, builder: (_, _) => const Text('channels')),
      GoRoute(
        path: Routes.adminRoles,
        builder: (_, _) => const Text('roles list'),
      ),
    ],
  ),
);

void main() {
  testWidgets('in the settings pane, an unsaved toggle makes leaving ask', (
    tester,
  ) async {
    final pane = SettingsSubPageStack();
    addTearDown(pane.dispose);
    await ConfigHarness(
      handler: (request) => request.method == 'PATCH'
          ? jsonOk({...roleJson(_role.id, _role.name), 'hoist': true})
          : null,
    ).pump(
      tester,
      SettingsSubPages(
        stack: pane,
        child: const RoleDetail(role: _role),
      ),
      overrides: [_ladder],
    );
    expect(pane.blocking, isFalse);

    await _toggleHoist(tester);
    expect(pane.blocking, isTrue, reason: 'the draft holds the pane');

    final leaving = pane.canLeave();
    await pumpFrames(tester);
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await pumpFrames(tester);
    expect(await leaving, isFalse);
    expect(find.text('1 unsaved change'), findsOneWidget);

    await tester.tap(find.text('Save changes'));
    await pumpFrames(tester);
    expect(pane.blocking, isFalse, reason: 'saved, nothing left to lose');
  });

  testWidgets('View server as this role asks before the draft is dropped', (
    tester,
  ) async {
    final pane = SettingsSubPageStack();
    addTearDown(pane.dispose);
    final container = await ConfigHarness().pump(
      tester,
      _routed(
        '/settings',
        SettingsSubPages(
          stack: pane,
          child: const RoleDetail(role: _role),
        ),
      ),
      overrides: [_ladder],
    );
    await _toggleHoist(tester);

    await tester.tap(find.byKey(viewAsRoleKey));
    await pumpFrames(tester);
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await pumpFrames(tester);
    expect(container.read(rolePreviewProvider), isNull);
    expect(find.text('1 unsaved change'), findsOneWidget);

    await tester.tap(find.byKey(viewAsRoleKey));
    await pumpFrames(tester);
    await tester.tap(find.text('Discard').last);
    await pumpFrames(tester);
    expect(container.read(rolePreviewProvider)?.roleId, _role.id);
    expect(find.text('channels'), findsOneWidget);
  });

  testWidgets('another tab asks before the draft is dropped', (tester) async {
    await ConfigHarness().pump(
      tester,
      const RoleDetail(role: _role),
      overrides: [_ladder],
    );
    await _toggleHoist(tester);

    await tester.tap(find.text('Permissions'));
    await pumpFrames(tester);
    await tester.tap(find.text('Keep editing'));
    await pumpFrames(tester);
    expect(find.text('1 unsaved change'), findsOneWidget);

    await tester.tap(find.text('Permissions'));
    await pumpFrames(tester);
    await tester.tap(find.text('Discard').last);
    await pumpFrames(tester);
    expect(find.text('Display role members separately'), findsNothing);
  });

  testWidgets('on its own route, back asks before the draft is dropped', (
    tester,
  ) async {
    final h = ConfigHarness();
    await h.pump(tester, const SizedBox.shrink(), overrides: [_ladder]);
    final navigator = tester.state<NavigatorState>(
      find.byWidgetPredicate((w) => w is Navigator),
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: RoleDetail(role: _role)),
      ),
    );
    await pumpFrames(tester);
    await _toggleHoist(tester);

    await navigator.maybePop();
    await pumpFrames(tester);
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Discard').last);
    await pumpFrames(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('crew'), findsNothing, reason: 'discarding leaves');
    expect(h.writes, isEmpty);
  });

  testWidgets('a cold deep link discards back to the roles list', (
    tester,
  ) async {
    await ConfigHarness().pump(
      tester,
      _routed('/settings/roles/${_role.id}', const RoleDetail(role: _role)),
      overrides: [_ladder],
    );
    await _toggleHoist(tester);

    await tester.binding.handlePopRoute();
    await pumpFrames(tester);
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Discard').last);
    await pumpFrames(tester);

    expect(find.text('roles list'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
