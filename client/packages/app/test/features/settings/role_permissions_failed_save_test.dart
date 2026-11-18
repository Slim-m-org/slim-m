// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A permissions save that fails, offline or refused, keeps the draft and says
/// the save failed, rather than refetching the roles into a load error that
/// remounts the tab and drops both.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/screens/admin/roles_screen.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _roles = [
  api.Role(
    id: 'role-everyone',
    name: 'everyone',
    permissions: Perm.viewChannel,
    isEveryone: true,
    createdAt: 0,
  ),
  api.Role(
    id: 'role-mod',
    name: 'mod',
    permissions: 0,
    isEveryone: false,
    createdAt: 0,
    position: 1,
  ),
];

Future<void> _pump(WidgetTester tester, {required bool online}) async {
  tester.view.physicalSize = const Size(1100, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var fetches = 0;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      myPermissionsProvider.overrideWithValue(Perm.all),
      membersProvider.overrideWith((ref) async => const []),
      modulePermissionsProvider.overrideWith((ref) async => const []),
      rolesProvider.overrideWith((ref) async {
        if (fetches++ > 0 && !online) {
          throw http.ClientException('offline');
        }
        return _roles;
      }),
      mockApiOverride((request) async {
        if (online) return http.Response('{"error":"nope"}', 403);
        throw http.ClientException('offline');
      }),
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
          ],
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  await tester.tap(find.text('mod').first);
  await pumpFrames(tester);
}

void main() {
  for (final online in [false, true]) {
    final how = online ? 'refused' : 'offline';
    testWidgets('a save that fails $how keeps the draft and its error', (
      tester,
    ) async {
      await _pump(tester, online: online);
      await tester.tap(find.bySemanticsLabel('Send messages').first);
      await tester.tap(find.bySemanticsLabel('Attach files').first);
      await pumpFrames(tester);
      expect(find.text('2 unsaved changes'), findsOneWidget);

      await tester.tap(find.text('Save changes'));
      await pumpFrames(tester);

      expect(find.text('Could not load roles.'), findsNothing);
      expect(find.textContaining('save permissions'), findsOneWidget);
      expect(find.text('2 unsaved changes'), findsOneWidget);
    });
  }
}
