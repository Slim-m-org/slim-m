// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roles pane's master-detail shape: the role list names each role's
/// member count, selecting one opens its Permissions/Members/Display tabs,
/// and a narrow window drills into the detail instead of showing both.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/admin/role_detail_screen.dart';
import 'package:slimm_app/src/screens/admin/roles_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// [RolesScreen] stays live to role changes through `roleChangeWatcherProvider`,
/// which needs a [SyncController] to read; this one opens no real socket.
class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {}
}

api.Role _role(
  String id,
  String name, {
  bool everyone = false,
  int memberCount = 0,
  int position = 0,
}) => api.Role(
  id: id,
  name: name,
  permissions: everyone ? Perm.viewChannel : Perm.manageMessages,
  isEveryone: everyone,
  createdAt: 0,
  memberCount: memberCount,
  position: position,
);

Future<void> _pump(
  WidgetTester tester,
  List<api.Role> roles, {
  Size size = const Size(900, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(_NoopSyncController.new),
      rolesProvider.overrideWith((ref) async => roles),
      myPermissionsProvider.overrideWithValue(Perm.manageRoles),
      membersProvider.overrideWith((ref) async => const []),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: GoRouter(
          initialLocation: Routes.adminRoles,
          routes: [
            GoRoute(
              path: Routes.adminRoles,
              builder: (context, state) => const RolesScreen(),
            ),
            GoRoute(
              path: '${Routes.adminRoles}/:roleId',
              builder: (context, state) =>
                  RoleDetailScreen(roleId: state.pathParameters['roleId']!),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the role list shows each role and its member count', (
    tester,
  ) async {
    await _pump(tester, [
      _role('role-everyone', 'everyone', everyone: true, memberCount: 12),
      _role('role-mod', 'mod', memberCount: 3),
    ]);

    // "everyone" is auto-selected (first, wide layout), so it shows twice; "mod" only once.
    expect(find.text('everyone'), findsAtLeastNWidgets(1));
    expect(find.text('mod'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('a wide window shows the role list beside the selected detail', (
    tester,
  ) async {
    await _pump(tester, [
      _role('role-everyone', 'everyone', everyone: true, memberCount: 12),
      _role('role-mod', 'mod', memberCount: 3),
    ]);

    // Wide enough for both panes: the list stays visible after selection.
    expect(find.text('mod'), findsOneWidget);
    await tester.tap(find.text('mod'));
    await tester.pumpAndSettle();

    expect(find.text('mod'), findsWidgets);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Members · 3'), findsOneWidget);
    expect(find.text('Display'), findsOneWidget);
  });

  testWidgets('a narrow window drills into the selected role and back', (
    tester,
  ) async {
    await _pump(tester, [
      _role('role-everyone', 'everyone', everyone: true, memberCount: 12),
      _role('role-mod', 'mod', memberCount: 3),
    ], size: const Size(400, 800));

    await tester.tap(find.text('mod'));
    await tester.pumpAndSettle();

    expect(find.text('Permissions'), findsOneWidget);
    expect(find.byTooltip('Back to roles'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to roles'));
    await tester.pumpAndSettle();

    expect(find.text('mod'), findsOneWidget);
    expect(find.text('Permissions'), findsNothing);
  });

  testWidgets('exactly one back button shows at compact width, before and '
      'after drilling into a role', (tester) async {
    await _pump(tester, [
      _role('role-everyone', 'everyone', everyone: true, memberCount: 12),
      _role('role-mod', 'mod', memberCount: 3),
    ], size: const Size(375, 800));

    expect(find.byIcon(AppIcons.back), findsOneWidget);

    await tester.tap(find.text('mod'));
    await tester.pumpAndSettle();

    // Drilled into the role: still exactly one back button, not two stacked app bars each with their own.
    expect(find.byIcon(AppIcons.back), findsOneWidget);
  });

  testWidgets('selecting a different role starts back on the Permissions tab', (
    tester,
  ) async {
    await _pump(tester, [
      _role('role-mods', 'mods', memberCount: 3),
      _role('role-everyone', 'everyone', everyone: true, memberCount: 12),
    ]);

    // "mods" is selected by default (wide layout, first role); leave Permissions.
    await tester.tap(find.text('Display'));
    await tester.pumpAndSettle();
    expect(find.text('Administrator'), findsNothing);

    await tester.tap(find.text('everyone').first);
    await tester.pumpAndSettle();

    expect(find.text('Administrator'), findsOneWidget);
    expect(
      find.text(
        'Every permission below, in every channel, ignoring overrides.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('create role is one plus at the end of the ROLES label row, '
      'inside the list column and on the 8px rhythm', (tester) async {
    await _pump(tester, [
      _role('role-everyone', 'everyone', everyone: true),
      _role('role-mod', 'mod'),
      _role('role-admin', 'admin'),
    ]);

    final plus = find.byTooltip(ActionLabels.createRole);
    expect(plus, findsOneWidget);

    final button = tester.getRect(plus);
    final label = tester.getRect(find.text('ROLES'));
    final firstRow = tester.getRect(find.byType(AppListRow).first);
    final column = tester.getRect(find.byType(ReorderableListView));
    expect(button.width, greaterThanOrEqualTo(AppSizes.rowPointer));
    expect(button.center.dy, closeTo(label.center.dy, 1));
    expect(button.left, greaterThanOrEqualTo(label.right));
    expect(button.right, closeTo(column.right - AppSpacing.s8, 1));
    expect(label.left - column.left, AppSpacing.s12);
    expect(firstRow.top - button.bottom, AppSpacing.s4);

    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(
      find.text('Set its permissions, members and display afterward.'),
      findsOneWidget,
    );
  });

  testWidgets('narrow: the list is the whole screen and still has exactly '
      'one create entry', (tester) async {
    await _pump(tester, [
      _role('role-everyone', 'everyone', everyone: true),
    ], size: const Size(400, 800));

    expect(find.byTooltip(ActionLabels.createRole), findsOneWidget);
    final button = tester.getRect(find.byTooltip(ActionLabels.createRole));
    expect(button.right, closeTo(400 - AppSpacing.s16 - AppSpacing.s8, 1));
  });
}
