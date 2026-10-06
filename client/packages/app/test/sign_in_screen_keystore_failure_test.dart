// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A key store that throws before the login call must not strand the button
/// in its busy state; the failure lands as a form error instead.
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

const _identity = {
  'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  'fingerprint': 'deadbeefcafebabefeedface1337d00d',
  'fingerprint_groups': [
    'dead',
    'beef',
    'cafe',
    'babe',
    'feed',
    'face',
    '1337',
    'd00d',
  ],
  'color_strip': [0, 1, 2, 3],
};

class _ThrowingKeyStore extends InMemoryKeyStore {
  bool armed = false;

  @override
  Future<KeyHandle> put(String name, String secret) => armed
      ? Future.error(StateError('keychain locked'))
      : super.put(name, secret);

  @override
  Future<String?> read(KeyHandle handle) =>
      armed ? Future.error(StateError('keychain locked')) : super.read(handle);
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('a throwing key store ends busy and shows a form error', (
    tester,
  ) async {
    final httpClient = MockClient((request) async {
      if (request.url.path == '/version') {
        return http.Response(
          jsonEncode({
            'name': 'slim-m',
            'version': '0.10.0',
            'protocol': 1,
            'identity': _identity,
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    final keyStore = _ThrowingKeyStore();
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(keyStore),
        probeApiProvider.overrideWithValue(
          (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
        ),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: httpClient,
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
    await tester.pump();
    await tester.enterText(
      find.byType(TextField).first,
      'https://chat.example',
    );
    await tester.enterText(find.byType(TextField).at(1), 'alice');
    await tester.enterText(find.byType(TextField).at(2), 'hunter2');
    keyStore.armed = true;
    await tester.ensureVisible(find.widgetWithText(AppButton, 'Sign in'));
    await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(
      find.byWidgetPredicate((w) => w is AppButton && w.busy),
      findsNothing,
    );
    expect(find.textContaining('Could not sign in'), findsOneWidget);
  });
}
