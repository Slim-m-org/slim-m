// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Use a different Space" is the one way off a remembered Space from the
/// sign-in screen, and it leads to the onboarding choice, so both an invite
/// and a bare server address stay reachable and still work end to end.
///
/// The routes mirror `router.dart`'s wiring for sign-in and onboarding; the
/// screens, dialogs and providers are the real ones.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_app/src/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mock_app_version.dart';

const _remembered = 'https://chat.example';

http.Client _server() => MockClient((request) async {
  final Object body = request.url.path == '/version'
      ? {'name': 'slim-m', 'version': '0.10.0', 'protocol': 1}
      : {
          'usable': true,
          'community': {
            'name': 'Space',
            'member_count': 3,
            'invited_by': 'alice',
            'uses_remaining': null,
            'expires_at': null,
          },
        };
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );
});

Future<ProviderContainer> _pumpRememberedSignIn(WidgetTester tester) async {
  final client = _server();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => Uri.parse(_remembered)),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: Routes.signIn,
    routes: [
      GoRoute(
        path: Routes.signIn,
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: Routes.onboarding,
        builder: (context, state) => OnboardingScreen(
          onServerChosen: (server, invite) {
            container.read(chosenServerProvider.notifier).choose(server);
            container.read(pendingInviteProvider.notifier).state = invite;
            context.go(Routes.signIn);
          },
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

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
  return container;
}

Future<void> _openDifferentSpace(WidgetTester tester) async {
  await tester.tap(find.text('Use a different Space'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('one action, not two, names the way off this Space', (
    tester,
  ) async {
    await _pumpRememberedSignIn(tester);

    expect(find.text('Use a different Space'), findsOneWidget);
    expect(find.text('Use a different server'), findsNothing);
    expect(find.text('Join a different Space'), findsNothing);
  });

  testWidgets('it is offered while creating an account too', (tester) async {
    await _pumpRememberedSignIn(tester);
    await tester.tap(find.text('Create an account instead'));
    await tester.pumpAndSettle();

    expect(find.text('Use a different Space'), findsOneWidget);
  });

  testWidgets('from a remembered Space it reaches both the invite and the '
      'address entry', (tester) async {
    await _pumpRememberedSignIn(tester);
    await _openDifferentSpace(tester);

    expect(find.text('Where are you joining?'), findsOneWidget);
    expect(find.text('I have an invite'), findsOneWidget);
    expect(find.text('Connect to a Space'), findsOneWidget);
  });

  testWidgets('redeeming an invite from there lands back on sign-in for the '
      "invite's Space, holding the code", (tester) async {
    final container = await _pumpRememberedSignIn(tester);
    await _openDifferentSpace(tester);

    await tester.tap(find.text('I have an invite'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, officialServer);
    await tester.enterText(find.byType(TextField).at(1), 'CODE1');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(find.text('Create an account'), findsWidgets);
    expect(container.read(pendingInviteProvider), 'CODE1');
    expect(
      container.read(chosenServerProvider)?.host,
      Uri.parse(officialServer).host,
    );
  });

  testWidgets('entering a different server address from there lands back on '
      'sign-in for that server', (tester) async {
    final container = await _pumpRememberedSignIn(tester);
    await _openDifferentSpace(tester);

    await tester.tap(find.text('Connect to a Space'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), officialServer);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome back'), findsOneWidget);
    expect(
      container.read(chosenServerProvider)?.host,
      Uri.parse(officialServer).host,
    );
    expect(container.read(pendingInviteProvider), isNull);
  });
}
