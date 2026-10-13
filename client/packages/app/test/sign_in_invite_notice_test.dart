// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The invite notice on the create-account form only speaks when it is true.
///
/// `/version` reports `invite_required` for a brand-new, unclaimed deployment
/// too, so the notice must not claim the Space is closed, and it must not tell
/// somebody who has just redeemed a code to go and redeem one.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mock_app_version.dart';

Future<void> _pumpCreateForm(
  WidgetTester tester, {
  String? pendingInvite,
}) async {
  final client = MockClient((request) async {
    return http.Response(
      jsonEncode(const {
        'name': 'slim-m',
        'version': '0.10.0',
        'protocol': 1,
        'invite_required': true,
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith(
        (ref) => Uri.parse('https://chat.example'),
      ),
      assumeNewAccountProvider.overrideWith((ref) => true),
      pendingInviteProvider.overrideWith((ref) => pendingInvite),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
      ),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: ref.watch(serverUrlProvider),
          session: ref.watch(sessionProvider),
          httpClient: client,
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const SignInScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('with no invite in hand the notice does not call the Space '
      'closed, since an unclaimed one reports the same flag', (tester) async {
    await _pumpCreateForm(tester);

    expect(find.text('Create an account'), findsOneWidget);
    expect(find.byIcon(AppIcons.invite), findsOneWidget);
    expect(find.textContaining('invite code'), findsOneWidget);
    expect(find.textContaining('first account'), findsOneWidget);
    expect(find.textContaining('invite only'), findsNothing);
  });

  testWidgets('the notice stays short and never points a joiner at admin '
      'settings', (tester) async {
    await _pumpCreateForm(tester);

    final text = tester.widget<Text>(find.textContaining('invite code')).data!;
    expect(text.split(' ').length, lessThanOrEqualTo(25));
    expect(text, isNot(contains('Settings')));
  });

  testWidgets('a code redeemed this session silences the notice', (
    tester,
  ) async {
    await _pumpCreateForm(tester, pendingInvite: 'abc234');

    expect(find.text('Create an account'), findsOneWidget);
    expect(find.byIcon(AppIcons.invite), findsNothing);
  });
}
