// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sign-in screen reached by connecting to a Space for the first time
/// neither greets the person as returning nor calls the key it just saved a
/// match for one pinned before.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/mock_app_version.dart';

const _server = 'https://chat.example';

Finder _field(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

ProviderContainer _container(KeyStore keyStore) {
  final client = MockClient((request) async {
    if (request.method == 'POST' && request.url.path == '/auth/login') {
      return http.Response(
        jsonEncode(
          const TokenPair(
            userId: 'user-1',
            accessToken: 'access-1',
            refreshToken: 'refresh-1',
            accessExpiresAt: 0,
          ).toJson(),
        ),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode({
        'name': 'slim-m',
        'display_name': 'Beta',
        'version': '0.90.0',
        'protocol': 1,
        'identity': {
          'public_key': _key,
          'fingerprint': 'deadbeefcafebabefeedface1337d00d',
          'fingerprint_groups': ['dead', 'beef', 'cafe', 'babe'],
          'color_strip': [0, 1, 2, 3],
        },
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keyStore),
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
  return container;
}

Future<void> _show(
  WidgetTester tester,
  ProviderContainer container,
  Widget home,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        key: ValueKey(home.runtimeType),
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: home,
      ),
    ),
  );
  await pumpFrames(tester, frames: 30);
}

void main() {
  setUpAll(mockAppVersion);

  Future<ProviderContainer> connectFirstTime(WidgetTester tester) async {
    final container = _container(InMemoryKeyStore());
    Uri? chosen;
    await _show(
      tester,
      container,
      OnboardingScreen(onServerChosen: (server, _) => chosen = server),
    );
    await tester.tap(find.text('Connect to a Space'));
    await pumpFrames(tester, frames: 30);
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is AppInput && w.semanticLabel == 'Server address',
      ),
      'chat.example',
    );
    await tester.tap(find.text('Continue'));
    await waitUntil(tester, () => chosen != null);
    container.read(chosenServerProvider.notifier).restore(chosen!);
    return container;
  }

  testWidgets('connecting for the first time says sign in, not welcome back', (
    tester,
  ) async {
    final container = await connectFirstTime(tester);

    await _show(tester, container, const SignInScreen());

    expect(find.text('Welcome back'), findsNothing);
    expect(find.text('Sign in'), findsWidgets);
    expect(find.text('Confirmed'), findsNothing);
  });

  testWidgets('a Space pinned on an earlier run is welcomed back', (
    tester,
  ) async {
    final keyStore = InMemoryKeyStore();
    await keyStore.put('server_identity:$_server', _key);
    final container = _container(keyStore);
    container.read(chosenServerProvider.notifier).restore(Uri.parse(_server));

    await _show(tester, container, const SignInScreen());

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Confirmed'), findsOneWidget);
  });

  testWidgets('after signing in, the next visit is welcomed back', (
    tester,
  ) async {
    final container = await connectFirstTime(tester);
    await _show(tester, container, const SignInScreen());
    await tester.enterText(_field('Username'), 'ava');
    await tester.enterText(_field('Password'), 'long enough pw');
    await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
    await waitUntil(
      tester,
      () => container.read(sessionProvider).tokens != null,
    );
    await pumpFrames(tester, frames: 30);
    await tester.pumpWidget(const SizedBox());

    await _show(tester, container, const SignInScreen());

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Confirmed'), findsOneWidget);
  });
}
