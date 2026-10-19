// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The invite role-grant picker offers only what the caller could actually
/// grant, because the server refuses the rest.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/invite_role_grant_picker.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// @everyone, one role the caller can grant, and one carrying a bit they do
/// not hold.
const _roles = [
  {
    'id': 'r-everyone',
    'name': '@everyone',
    'permissions': 0,
    'is_everyone': true,
    'created_at': 0,
  },
  {
    'id': 'r-mod',
    'name': 'moderator',
    'permissions': Perm.manageMessages,
    'is_everyone': false,
    'created_at': 0,
  },
  {
    'id': 'r-admin',
    'name': 'superuser',
    'permissions': Perm.administrator,
    'is_everyone': false,
    'created_at': 0,
  },
];

Future<void> _pump(
  WidgetTester tester,
  int myPermissions, {
  bool rolesFetchFails = false,
}) async {
  final client = MockClient((request) async {
    if (rolesFetchFails && request.url.path == '/roles') {
      return http.Response('', 500);
    }
    final body = request.url.path == '/roles' ? _roles : const <Object>[];
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      myPermissionsProvider.overrideWithValue(myPermissions),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: client,
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: InviteRoleGrantPicker(selected: null, onChanged: (_) {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a caller without MANAGE_ROLES is offered nothing at all', (
    tester,
  ) async {
    // Holds manageMessages, so the moderator role IS grantable by the bit
    // check below. Only the MANAGE_ROLES gate can hide the picker here, which
    // is what stops this passing for the wrong reason.
    await _pump(tester, Perm.createInvite | Perm.manageMessages);

    // Absent, not disabled: the server refuses this combination outright.
    expect(find.text('Role granted'), findsNothing);
  });

  testWidgets(
    'a failed roles fetch says so, rather than reading as no grantable role',
    (tester) async {
      await _pump(
        tester,
        Perm.manageRoles | Perm.manageMessages,
        rolesFetchFails: true,
      );

      // Not the same absence a caller with genuinely nothing to grant sees.
      expect(find.text('Role granted'), findsNothing);
      expect(
        find.text('Could not check which roles you can grant.'),
        findsOneWidget,
      );
      expect(find.byType(AppErrorState), findsOneWidget);
    },
  );

  testWidgets('only roles the caller could grant are offered', (tester) async {
    await _pump(tester, Perm.manageRoles | Perm.manageMessages);

    expect(find.text('Role granted'), findsOneWidget);
    await tester.tap(find.text('Role granted'));
    await tester.pumpAndSettle();

    expect(find.text('moderator'), findsOneWidget);
    // Carries ADMINISTRATOR, which this caller does not hold. Offering it
    // would invite a 403, which is the thing the filter exists to stop.
    expect(find.text('superuser'), findsNothing);
    // @everyone is never a grant: everyone already has it.
    expect(find.text('@everyone'), findsNothing);
    // Scoped to the sheet: the row behind it still shows "None" as its
    // current value, so an unscoped finder matches twice.
    expect(
      find.descendant(of: find.byType(AppMenu), matching: find.text('None')),
      findsOneWidget,
    );
  });

  testWidgets('an administrator can grant every role', (tester) async {
    await _pump(tester, -1);

    await tester.tap(find.text('Role granted'));
    await tester.pumpAndSettle();

    expect(find.text('moderator'), findsOneWidget);
    expect(find.text('superuser'), findsOneWidget);
  });

  // The reported bug: a fixed-width, bordered AppMenu nested inside the sheet.
  testWidgets('on a phone the picker is one surface, spanning the full width', (
    tester,
  ) async {
    const window = Size(360, 800);
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, -1);

    await tester.tap(find.text('Role granted'));
    await tester.pumpAndSettle();

    expect(
      find.byType(AppMenu),
      findsNothing,
      reason:
          'the sheet already draws one surface; AppMenu would nest a '
          'second, bordered card inside it',
    );
    expect(
      tester.getRect(find.byType(BottomSheet)).width,
      window.width,
      reason: 'a phone sheet should be edge to edge, not a floating card',
    );
  });
}
