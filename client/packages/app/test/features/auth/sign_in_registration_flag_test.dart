// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Registering marks the session as a new account, so the what's-new check
/// has nothing to catch it up on; a refused registration takes the mark back.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/whats_new_controller.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../support/mock_app_version.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

Future<ProviderContainer> _register(
  WidgetTester tester, {
  required int status,
}) async {
  final client = MockClient((request) async {
    final body = switch (request.url.path) {
      '/version' => {'name': 'slim-m', 'version': '0.10.0', 'protocol': 1},
      '/auth/register' when status == 200 => _tokens.toJson(),
      _ => {'error': 'taken'},
    };
    final code = request.url.path == '/auth/register' ? status : 200;
    return http.Response(
      jsonEncode(body),
      code,
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
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
  Finder input(String label) =>
      find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);
  await tester.enterText(input('Username'), 'dana');
  await tester.enterText(input('Password'), 'long enough pw');
  await tester.tap(find.widgetWithText(AppButton, 'Create account'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('a successful registration marks the account as new', (
    tester,
  ) async {
    final container = await _register(tester, status: 200);

    expect(container.read(justRegisteredProvider), isTrue);
  });

  testWidgets('a refused registration leaves no mark behind', (tester) async {
    final container = await _register(tester, status: 409);

    expect(container.read(justRegisteredProvider), isFalse);
  });
}
