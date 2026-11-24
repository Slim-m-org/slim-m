// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Roles can be reordered from the keyboard: Alt+Up and Alt+Down move the
/// focused role one place, the same path a drag takes.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/screens/admin/roles_screen.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/role_ladder.dart';
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

api.Role _role(String id, int position) => api.Role(
  id: id,
  name: id,
  permissions: Perm.manageMessages,
  isEveryone: false,
  createdAt: 0,
  position: position,
);

Future<List<List<String>>> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final reorders = <List<String>>[];
  final roles = [_role('alpha', 3), _role('beta', 2), _role('gamma', 1)];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      rolesProvider.overrideWith((ref) async => roles),
      myPermissionsProvider.overrideWithValue(Perm.manageRoles),
      membersProvider.overrideWith((ref) async => const []),
      roleLadderProvider.overrideWithValue(
        const RoleLadder(permissions: Perm.manageRoles, topPosition: 10),
      ),
      mockApiOverride((request) async {
        if (request.method == 'PATCH' && request.url.path == '/roles/reorder') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          reorders.add((body['role_ids'] as List).cast<String>());
        }
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const RolesScreen(),
      ),
    ),
  );
  await pumpFrames(tester, frames: 40);
  return reorders;
}

Future<void> _focusRow(WidgetTester tester, String name) async {
  Focus.of(tester.element(find.text(name))).requestFocus();
  await tester.pump();
}

Future<void> _altArrow(WidgetTester tester, LogicalKeyboardKey arrow) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(arrow);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await pumpFrames(tester, frames: 40);
}

void main() {
  testWidgets('Alt+Up moves the focused role one place up', (tester) async {
    final reorders = await _pump(tester);
    await _focusRow(tester, 'beta');

    await _altArrow(tester, LogicalKeyboardKey.arrowUp);

    expect(reorders, [
      ['beta', 'alpha', 'gamma'],
    ]);
  });

  testWidgets('Alt+Down moves it down, and the last role stays put', (
    tester,
  ) async {
    final reorders = await _pump(tester);
    await _focusRow(tester, 'beta');
    await _altArrow(tester, LogicalKeyboardKey.arrowDown);
    expect(reorders, [
      ['alpha', 'gamma', 'beta'],
    ]);

    reorders.clear();
    await _focusRow(tester, 'gamma');
    await _altArrow(tester, LogicalKeyboardKey.arrowDown);
    expect(reorders, isEmpty);
  });
}
