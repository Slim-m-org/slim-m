// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space settings route to a reset code.
///
/// Issuing already worked, from a member's profile popover. Nothing in Space
/// settings mentioned recovery, so an administrator looking where admin
/// actions live found nothing and read that as the feature being absent. What
/// these hold is that the second route exists, that it reaches the same sheet,
/// and that it needs ADMINISTRATOR the way the server route does.
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
import 'package:slimm_app/src/features/settings/screens/admin/account_recovery_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_app/src/action_labels.dart';

const _tokens = api.TokenPair(
  userId: 'admin-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

/// Two members, so picking one is a real choice rather than the only row.
String _membersJson() => jsonEncode([
  {
    'id': 'user-9',
    'username': 'ada',
    'display_name': 'Ada',
    'created_at': 0,
    'permissions': 0,
  },
  {
    'id': 'user-4',
    'username': 'grace',
    'display_name': 'Grace',
    'created_at': 0,
    'permissions': 0,
  },
]);

Future<void> _pump(WidgetTester tester, {required int permissions}) async {
  final client = MockClient((request) async {
    if (request.url.path == '/members') {
      return http.Response(
        _membersJson(),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      '{}',
      404,
      headers: {'content-type': 'application/json'},
    );
  });

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      myPermissionsProvider.overrideWithValue(permissions),
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
        home: const Scaffold(
          body: SingleChildScrollView(child: AccountRecoveryPane()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an administrator reaches the issuing sheet without ever opening '
      'a member popover', (tester) async {
    await _pump(tester, permissions: Perm.administrator);

    // The pane explains recovery, because there is no email path to guess at.
    expect(find.text(resetCodesDescription), findsOneWidget);

    await tester.tap(find.text(ActionLabels.createResetCode));
    await tester.pumpAndSettle();
    expect(
      find.text('Choose a member'),
      findsOneWidget,
      reason: 'the action picks who it is for rather than asking for an id',
    );

    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();

    // textContaining('Ada') would match the picker's own row; these do not.
    expect(
      find.text('Choose a member'),
      findsNothing,
      reason: 'the picker closes once a member is chosen',
    );
    expect(
      find.text('Password reset code for Ada'),
      findsOneWidget,
      reason: 'the title only _ResetCodeSheet renders, for the member picked',
    );
  });

  testWidgets('a cancelled pick issues nothing', (tester) async {
    await _pump(tester, permissions: Perm.administrator);

    await tester.tap(find.text(ActionLabels.createResetCode));
    await tester.pumpAndSettle();
    expect(find.text('Choose a member'), findsOneWidget);

    Navigator.of(tester.element(find.text('Choose a member'))).pop();
    await tester.pumpAndSettle();

    expect(find.text('Choose a member'), findsNothing);
    expect(
      find.text(ActionLabels.createResetCode),
      findsOneWidget,
      reason: 'backing out returns to the pane, having issued nothing',
    );
  });

  /// Hidden, not shown inert. `space_settings_section.dart`'s own gate states
  /// the rule - a member without the bit should not see the surface exists at
  /// all rather than be shown it and left to answer 403 - and
  /// `removed_members_screen.dart` hides its ADMINISTRATOR-only delete the same
  /// way. Reachable only by typing the route, since the pane is not listed.
  testWidgets('without ADMINISTRATOR the action is absent, not disabled', (
    tester,
  ) async {
    await _pump(tester, permissions: Perm.manageServer);

    expect(
      find.text(ActionLabels.createResetCode),
      findsNothing,
      reason: 'the action must not be visible to somebody who cannot take it',
    );
    expect(
      find.textContaining('needs the administrator permission'),
      findsOneWidget,
      reason: 'but the page still says why it is empty; see decision 0013',
    );
  });
}
