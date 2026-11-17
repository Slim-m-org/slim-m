// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bot roles in the Roles list keep their real rank, and a role only bots
/// hold says so in its editor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_detail.dart';
import 'package:slimm_app/src/features/settings/screens/admin/roles_screen.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Role _role(
  String id,
  String name, {
  bool everyone = false,
  bool botsRole = false,
  String? botId,
  int position = 0,
}) => api.Role(
  id: id,
  name: name,
  permissions: Perm.manageMessages,
  isEveryone: everyone,
  isBotsRole: botsRole,
  managedBotId: botId,
  createdAt: 0,
  memberCount: 1,
  position: position,
);

api.UserProfile _member(
  String id,
  String name, {
  bool bot = false,
  List<String> roles = const [],
}) => api.UserProfile(
  id: id,
  username: id,
  displayName: name,
  createdAt: 0,
  isBot: bot,
  roleIds: roles,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<api.Role> roles,
  required List<api.UserProfile> members,
  required Widget home,
  Size size = const Size(900, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      rolesProvider.overrideWith((ref) async => roles),
      myPermissionsProvider.overrideWithValue(Perm.manageRoles),
      membersProvider.overrideWith((ref) async => members),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => Scaffold(body: home),
            ),
            GoRoute(
              path: Routes.adminBots,
              builder: (context, state) => const Text('bots page'),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('bot roles render as bot rows at their real rank', (
    tester,
  ) async {
    await _pump(
      tester,
      roles: [
        _role('r-tickets', 'Tickets', botId: 'bot-t', position: 5),
        _role('r-mod', 'mod', position: 4),
        _role('r-bots', 'Bots', botsRole: true, position: 3),
        _role('r-warns', 'Warns', botId: 'bot-w', position: 2),
        _role('r-everyone', 'everyone', everyone: true),
      ],
      members: [
        _member('bot-t', 'Ticket Bot', bot: true),
        _member('bot-w', 'Warn Bot', bot: true),
      ],
      home: const RolesPane(),
    );

    expect(find.text('Ticket Bot'), findsOneWidget);
    expect(find.text('Warn Bot'), findsOneWidget);
    expect(find.text('All bots'), findsOneWidget);
    final listLabels = tester
        .widgetList<AppListRow>(find.byType(AppListRow))
        .map((r) => r.label)
        .toList();
    expect(listLabels, [
      'Ticket Bot',
      'mod',
      'All bots',
      'Warn Bot',
      'everyone',
    ]);
    expect(
      tester
          .widgetList<AppListRow>(find.byType(AppListRow))
          .where((r) => r.trailing is AppBadge)
          .map((r) => r.label),
      ['Ticket Bot', 'All bots', 'Warn Bot'],
    );
  });

  testWidgets('a role only bots hold points to the bots page', (tester) async {
    final role = _role('r-auto', 'bot-automod', position: 3);
    await _pump(
      tester,
      roles: [role],
      members: [
        _member('bot-a', 'Auto', bot: true, roles: ['r-auto']),
      ],
      home: RoleDetail(role: role),
    );
    expect(find.text(botOnlyRoleHint), findsOneWidget);
    await tester.tap(find.text('Open bots'));
    await tester.pumpAndSettle();
    expect(find.text('bots page'), findsOneWidget);
  });

  testWidgets('a role a person holds shows no bot hint', (tester) async {
    final role = _role('r-mod', 'bot-moderator', position: 3);
    await _pump(
      tester,
      roles: [role],
      members: [
        _member('bot-a', 'Auto', bot: true, roles: ['r-mod']),
        _member('u1', 'Ann', roles: ['r-mod']),
      ],
      home: RoleDetail(role: role),
    );
    expect(find.text(botOnlyRoleHint), findsNothing);
  });
}
