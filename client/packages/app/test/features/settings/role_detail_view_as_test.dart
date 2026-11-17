// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A role below the viewer offers "View server as this role", which starts the preview and goes
/// back to the shell; a role at or above them, or a viewer without Manage roles, offers nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/role_preview/providers/role_preview_controller.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_detail.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/role_ladder.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../role_preview/role_preview_fixture.dart';

const _above = api.Role(
  id: 'role-top',
  name: 'top',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
  position: 9,
);

const _everyone = api.Role(
  id: 'role-everyone',
  name: '@everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  api.Role role, {
  int permissions = Perm.manageRoles,
}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: previewTokens),
      ),
      mockApiOverride(previewHandler),
      membersProvider.overrideWith((ref) async => const []),
      roleLadderProvider.overrideWithValue(
        RoleLadder(permissions: permissions, topPosition: 5),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/settings/roles',
    routes: [
      GoRoute(
        path: '/settings/roles',
        builder: (context, state) => Scaffold(body: RoleDetail(role: role)),
      ),
      GoRoute(
        path: '/channels',
        builder: (context, state) => const Text('the shell'),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await pumpFrames(tester);
  return container;
}

void main() {
  testWidgets(
    'a role below the viewer opens the preview and returns to the shell',
    (tester) async {
      final container = await _pump(tester, previewRole);
      expect(find.text('View server as this role'), findsOneWidget);

      await tester.tap(find.byKey(viewAsRoleKey));
      await pumpFrames(tester);

      expect(container.read(rolePreviewProvider)?.roleId, previewRole.id);
      expect(container.read(rolePreviewProvider)?.roleName, 'cs');
      expect(find.text('the shell'), findsOneWidget);
    },
  );

  testWidgets('@everyone can always be previewed by a role manager', (
    tester,
  ) async {
    await _pump(tester, _everyone);
    expect(find.byKey(viewAsRoleKey), findsOneWidget);
  });

  testWidgets('a role at or above the viewer offers no preview', (
    tester,
  ) async {
    await _pump(tester, _above);
    expect(find.byKey(viewAsRoleKey), findsNothing);
  });

  testWidgets('a viewer without Manage roles is offered no preview', (
    tester,
  ) async {
    await _pump(tester, previewRole, permissions: Perm.viewModerationHistory);
    expect(find.byKey(viewAsRoleKey), findsNothing);
  });
}
