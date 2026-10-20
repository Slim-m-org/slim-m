// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the compiled-in official server collapsing the address field on
/// sign-in: skipped entirely, with "Use a different Space" as the one way to
/// another address, and never collapsed for any other address. Also covers the
/// related default mode: creating an account, when onboarding signals a
/// fresh join, versus signing in otherwise.
///
/// Split out of sign_in_screen_test.dart to stay under the file budget.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/mock_app_version.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

/// Answers every `/version` probe with a bare, identity-free body and
/// everything else with an empty object, so no test in this file ever makes
/// a real network call to the compiled-in official host.
http.Client _quietProbe() => MockClient((request) async {
  if (request.method == 'GET' && request.url.path == '/version') {
    return http.Response(
      jsonEncode({'name': 'slim-m', 'version': '0.10.0', 'protocol': 1}),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
  return http.Response('{}', 200);
});

Future<ProviderContainer> _pumpSignIn(
  WidgetTester tester, {
  required Uri server,
  http.Client? httpClient,
  bool assumeNewAccount = false,
}) async {
  final client = httpClient ?? _quietProbe();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => server),
      assumeNewAccountProvider.overrideWith((ref) => assumeNewAccount),
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
  return container;
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets(
    'the official server needs no address field, only username and password',
    (tester) async {
      await _pumpSignIn(tester, server: Uri.parse(officialServer));

      expect(
        find.byType(TextField),
        findsNWidgets(2),
        reason: 'username and password only - no address field to fill in',
      );
      expect(find.text('Use a different Space'), findsOneWidget);
    },
  );

  testWidgets(
    'a self-hosted address keeps the full flow, with no default to skip',
    (tester) async {
      await _pumpSignIn(tester, server: Uri.parse('https://chat.example'));

      expect(
        find.byType(TextField),
        findsNWidgets(3),
        reason: 'no compiled-in default for this address, so nothing to skip',
      );
      expect(find.text('Use a different Space'), findsOneWidget);
    },
  );

  testWidgets(
    'signing in with the address collapsed still connects to the official '
    'server',
    (tester) async {
      String? loggedInHost;
      final httpClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/auth/login') {
          loggedInHost = request.url.host;
          return http.Response(
            jsonEncode(_tokens.toJson()),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && request.url.path == '/version') {
          return http.Response(
            jsonEncode({'name': 'slim-m', 'version': '0.10.0', 'protocol': 1}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      await _pumpSignIn(
        tester,
        server: Uri.parse(officialServer),
        httpClient: httpClient,
      );

      await tester.enterText(find.byType(TextField).at(0), 'alice');
      await tester.enterText(find.byType(TextField).at(1), 'hunter2');
      await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(loggedInHost, Uri.parse(officialServer).host);
    },
  );

  testWidgets(
    'arriving at the official server with no invite still opens on signing '
    'in, absent the onboarding flag that means a fresh join',
    (tester) async {
      await _pumpSignIn(tester, server: Uri.parse(officialServer));

      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('Create an account instead'), findsOneWidget);
    },
  );

  testWidgets(
    'choosing "Join the official Space" in onboarding opens sign-in on '
    'creating an account, skipping the extra tap a newcomer has no use for',
    (tester) async {
      final container = await _pumpSignIn(
        tester,
        server: Uri.parse(officialServer),
        assumeNewAccount: true,
      );

      expect(find.text('Create an account'), findsOneWidget);
      expect(find.text('I already have an account'), findsOneWidget);
      expect(
        container.read(assumeNewAccountProvider),
        isFalse,
        reason:
            'consumed on the first read, so a later sign-out on this same '
            'address - which skips onboarding - is not mistaken for another '
            'fresh join',
      );
    },
  );
}
