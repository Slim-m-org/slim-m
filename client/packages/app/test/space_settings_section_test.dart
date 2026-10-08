// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Space settings as a nav beside embedded panes, matching personal
/// settings' shape, with each pane gated on the server bit its surface
/// requires. On a wide window choosing a pane embeds it beside the nav; on a
/// compact one the same row pushes the standalone admin route, so a phone
/// keeps the real, deep-linkable screens.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/admin/invites_screen.dart';
import 'package:slimm_app/src/screens/admin/reports_screen.dart';
import 'package:slimm_app/src/screens/admin/roles_screen.dart';
import 'package:slimm_app/src/screens/space_settings_screen.dart';
import 'package:slimm_app/src/widgets/settings_notice.dart';
import 'package:slimm_app/src/widgets/space_settings_section.dart'
    show spaceSettingsReachable;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_app/src/action_labels.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Answers the join-policy read with its map shape and every list endpoint
/// (reports, roles, invites, channels) with an empty list.
http.Response _respond(http.Request request) =>
    request.url.path.endsWith('/space/settings')
    ? http.Response(
        jsonEncode({'join_policy': 'invite'}),
        200,
        headers: {'content-type': 'application/json'},
      )
    : http.Response('[]', 200, headers: {'content-type': 'application/json'});

List<Override> _overrides(int permissions) => [
  keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
  sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
  myPermissionsProvider.overrideWithValue(permissions),
  myVisibleChannelsProvider.overrideWith((ref) async => const []),
  apiProvider.overrideWith((ref) {
    final client = api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: MockClient((request) async => _respond(request)),
    );
    ref.onDispose(client.close);
    return client;
  }),
];

Future<void> _pump(
  WidgetTester tester, {
  required int permissions,
  double width = 1100,
  List<Override> extraOverrides = const [],
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [..._overrides(permissions), ...extraOverrides],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: Routes.spaceSettings,
    routes: [
      GoRoute(
        path: Routes.spaceSettings,
        builder: (_, __) => const SpaceSettingsScreen(),
      ),
      GoRoute(
        path: Routes.adminInvites,
        builder: (_, __) => const Scaffold(body: Text('invites-route')),
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
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('wide: the nav lists every gated area and embeds the first '
      'pane beside it', (tester) async {
    // Every gating bit, so every pane renders. Who can join is not one now.
    await _pump(tester, permissions: -1);

    expect(find.text('Moderation'), findsOneWidget);
    expect(find.text('Access'), findsOneWidget);
    expect(find.text('Configuration'), findsOneWidget);
    expect(find.text(ActionLabels.operationsGroup), findsOneWidget);
    for (final label in [
      'Reports',
      'Removed members',
      'Invites',
      'Roles',
      'Channel permissions',
      'Emoji',
      ActionLabels.retentionAndLimits,
      'Analytics',
      'Storage',
      'Server metrics',
    ]) {
      expect(find.text(label), findsWidgets, reason: '$label missing');
    }
    expect(find.byType(ListTile), findsNothing);
    // Wide always shows something: the first pane is embedded, not routed.
    expect(find.byType(ReportsPane), findsOneWidget);
    expect(find.text('The queue is empty.'), findsOneWidget);

    // Geometry, not just text: the four panes sit under SERVER, between CONFIGURATION and ADDONS.
    final configurationY = tester.getTopLeft(find.text('Configuration')).dy;
    final serverY = tester
        .getTopLeft(find.text(ActionLabels.operationsGroup))
        .dy;
    final performanceY = tester
        .getTopLeft(find.text(ActionLabels.retentionAndLimits))
        .dy;
    final addonsY = tester.getTopLeft(find.text('Addons')).dy;
    expect(configurationY, lessThan(serverY));
    expect(serverY, lessThan(performanceY));
    expect(performanceY, lessThan(addonsY));
  });

  testWidgets(
    'MANAGE_SERVER alone shows the Server group, with Configuration down to '
    'just Emoji',
    (tester) async {
      // Emoji stays MANAGE_SERVER, same as before the split, so Configuration survives on that pane alone.
      await _pump(tester, permissions: Perm.manageServer);

      expect(find.text(ActionLabels.operationsGroup), findsOneWidget);
      for (final label in [
        ActionLabels.retentionAndLimits,
        'Analytics',
        'Storage',
        'Server metrics',
      ]) {
        expect(find.text(label), findsWidgets, reason: '$label missing');
      }
      expect(find.text('Configuration'), findsOneWidget);
      expect(find.text('Emoji'), findsWidgets);
      for (final label in ['Roles', 'Channel permissions']) {
        expect(
          find.text(label),
          findsNothing,
          reason: '$label needs a different bit',
        );
      }
    },
  );

  testWidgets('wide: choosing another pane swaps it in place, with the create '
      'role entry in the roles list', (tester) async {
    await _pump(tester, permissions: -1);

    await tester.tap(find.text('Roles'));
    await tester.pumpAndSettle();

    expect(find.byType(RolesPane), findsOneWidget);
    expect(find.byType(ReportsPane), findsNothing);
    expect(find.byTooltip(ActionLabels.createRole), findsOneWidget);
  });

  testWidgets('compact: a pane naming a route pushes the standalone screen '
      'rather than drilling in place', (tester) async {
    await _pump(tester, permissions: -1, width: 500);

    expect(find.byType(ReportsPane), findsNothing);
    await tester.tap(find.text('Invites'));
    await tester.pumpAndSettle();

    expect(find.text('invites-route'), findsOneWidget);
    expect(find.byType(InvitesPane), findsNothing);
  });

  testWidgets('VIEW_MODERATION_HISTORY alone reaches Reports, history only', (
    tester,
  ) async {
    expect(spaceSettingsReachable(Perm.viewModerationHistory), isTrue);
    await _pump(tester, permissions: Perm.viewModerationHistory);

    expect(find.text('Reports'), findsWidgets);
    expect(find.byType(ReportsPane), findsOneWidget);
    expect(
      find.text('Open'),
      findsNothing,
      reason: 'GET /reports needs MANAGE_MESSAGES, so no Open queue here',
    );
  });

  testWidgets('a group with none of its panes visible renders no header at '
      'all', (tester) async {
    // CREATE_INVITE alone: only the Access group has anything in it.
    await _pump(tester, permissions: Perm.createInvite);

    expect(find.text('Access'), findsOneWidget);
    expect(find.text('Invites'), findsWidgets);
    expect(
      find.text('Moderation'),
      findsNothing,
      reason: 'Reports and Removed members are both hidden here',
    );
    expect(
      find.text('Configuration'),
      findsNothing,
      reason: 'Roles, permissions and emoji are all hidden',
    );
  });

  testWidgets(
    'Channel permissions alone opens for MANAGE_ROLES held only through one '
    "visible channel's overwrite, with Roles itself staying hidden",
    (tester) async {
      // Base is CREATE_INVITE alone, so only the channel can explain the pane.
      await _pump(
        tester,
        permissions: Perm.createInvite,
        extraOverrides: [
          myVisibleChannelsProvider.overrideWith(
            (ref) async => const [
              api.Channel(
                id: 'c1',
                name: 'general',
                kind: 'text',
                createdAt: 0,
                permissions: Perm.manageRoles,
              ),
            ],
          ),
        ],
      );

      expect(find.text('Channel permissions'), findsOneWidget);
      expect(
        find.text('Roles'),
        findsNothing,
        reason:
            'role CRUD is deployment-wide; a channel overwrite grants '
            'nothing towards it',
      );
    },
  );

  testWidgets('a caller holding none of the gating bits gets a stated reason, '
      'not a blank page', (tester) async {
    await _pump(tester, permissions: 0);

    expect(find.byType(SettingsNotice), findsOneWidget);
    expect(
      find.textContaining('None of your roles grant access'),
      findsOneWidget,
    );
    expect(
      find.textContaining('An administrator can grant you access'),
      findsOneWidget,
      reason:
          'a stated absence that does not say what would change it is only '
          'half the fix',
    );
  });

  testWidgets('the join-policy row still opens its picker, from Invites', (
    tester,
  ) async {
    await _pump(tester, permissions: -1);
    // Who can join moved in with the invites; it is a row there, not a pane.
    await tester.tap(find.text('Invites'));
    await tester.pumpAndSettle();
    // Tapping the row opens the picker directly; there is no pane to enter.
    await tester.tap(find.text('Who can join'));
    await tester.pumpAndSettle();
    expect(find.text('Anyone with the address'), findsOneWidget);
  });
}
