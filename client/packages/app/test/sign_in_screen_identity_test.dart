// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the sign-in screen's connection-trust behaviour: the shared
/// https rule, address reduction on submit, the identity tick reflecting a
/// real pin comparison, and binding identity confirmation to connecting.
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
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mock_app_version.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _server = 'https://chat.example';

const _identityA = {
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

const _identityB = {
  'public_key': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  'fingerprint': 'facefeedf00dd00dfacefeedf00dd00d',
  'fingerprint_groups': [
    'face',
    'feed',
    'f00d',
    'd00d',
    'face',
    'feed',
    'f00d',
    'd00d',
  ],
  'color_strip': [4, 5, 0, 1],
};

String _handleFor(String server) => 'server_identity:$server';

/// Overrides both the throwaway probe client and the real one with the same
/// mock, so a test can drive `/version` and `/auth/login` from one place.
List<Override> _overridesFor({
  required KeyStore keyStore,
  required http.Client httpClient,
}) => [
  keyStoreProvider.overrideWithValue(keyStore),
  serverUrlProvider.overrideWith((ref) => Uri.parse(_server)),
  probeApiProvider.overrideWithValue(
    (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
  ),
  apiProvider.overrideWith((ref) {
    final api = SlimmApi(
      baseUrl: ref.watch(serverUrlProvider),
      session: ref.watch(sessionProvider),
      httpClient: httpClient,
    );
    ref.onDispose(api.close);
    return api;
  }),
];

void main() {
  setUpAll(mockAppVersion);

  group('the https rule', () {
    testWidgets('a public http address is refused before it is sent', (
      tester,
    ) async {
      var loginCalls = 0;
      final httpClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/auth/login') {
          loginCalls++;
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: _overridesFor(
          keyStore: InMemoryKeyStore(),
          httpClient: httpClient,
        ),
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

      await tester.enterText(
        find.byType(TextField).first,
        'http://chat.example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), 'alice');
      await tester.enterText(find.byType(TextField).at(2), 'hunter2');
      await tester.ensureVisible(find.widgetWithText(AppButton, 'Sign in'));
      await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Use https'), findsOneWidget);
      expect(
        loginCalls,
        0,
        reason: 'a refused address must never reach the network',
      );
      expect(container.read(chosenServerProvider), isNull);
    });
  });

  group('address reduction on submit', () {
    testWidgets('userinfo, a path and a query are stripped before '
        'persisting', (tester) async {
      var loginCalls = 0;
      final httpClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/auth/login') {
          loginCalls++;
          return http.Response(
            jsonEncode(_tokens.toJson()),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: _overridesFor(
          keyStore: InMemoryKeyStore(),
          httpClient: httpClient,
        ),
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

      await tester.enterText(
        find.byType(TextField).first,
        'https://user:pass@chat.example/some/path?x=1',
      );
      await tester.enterText(find.byType(TextField).at(1), 'alice');
      await tester.enterText(find.byType(TextField).at(2), 'hunter2');
      await tester.ensureVisible(find.widgetWithText(AppButton, 'Sign in'));
      await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
      await tester.pumpAndSettle();

      final chosen = container.read(chosenServerProvider);
      expect(chosen, Uri.parse('https://chat.example'));
      expect(
        chosen!.userInfo,
        isEmpty,
        reason: 'a Basic auth header must never ride along silently',
      );
      expect(loginCalls, 1);
    });
  });

  group('the identity tick', () {
    testWidgets('a fetched key matching the pin shows the confirmed tick', (
      tester,
    ) async {
      final keyStore = InMemoryKeyStore();
      await keyStore.put(
        _handleFor(_server),
        _identityA['public_key'] as String,
      );

      final httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/version') {
          return http.Response(
            jsonEncode({
              'name': 'slim-m',
              'version': '0.10.0',
              'protocol': 1,
              'identity': _identityA,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: _overridesFor(keyStore: keyStore, httpClient: httpClient),
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

      expect(find.byIcon(AppIcons.check), findsOneWidget);
      expect(find.byIcon(AppIcons.danger), findsNothing);
    });

    testWidgets(
      'a fetched key that does not match the pin shows the mismatch glyph, '
      'not the confirmed tick',
      (tester) async {
        final keyStore = InMemoryKeyStore();
        await keyStore.put(
          _handleFor(_server),
          _identityA['public_key'] as String,
        );

        final httpClient = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/version') {
            return http.Response(
              jsonEncode({
                'name': 'slim-m',
                'version': '0.10.0',
                'protocol': 1,
                'identity': _identityB,
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
        });

        final container = ProviderContainer(
          overrides: _overridesFor(keyStore: keyStore, httpClient: httpClient),
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

        expect(
          find.byIcon(AppIcons.check),
          findsNothing,
          reason:
              'the old call site read only whether identity was present, '
              'which a mismatched server also satisfies',
        );
        expect(find.byIcon(AppIcons.danger), findsOneWidget);
      },
    );

    testWidgets('no pin yet renders neither glyph', (tester) async {
      final httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/version') {
          return http.Response(
            jsonEncode({
              'name': 'slim-m',
              'version': '0.10.0',
              'protocol': 1,
              'identity': _identityA,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: _overridesFor(
          keyStore: InMemoryKeyStore(),
          httpClient: httpClient,
        ),
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

      expect(find.byIcon(AppIcons.check), findsNothing);
      expect(find.byIcon(AppIcons.danger), findsNothing);
    });
  });

  group('identity confirmation on connect', () {
    testWidgets(
      'a mismatched pinned identity blocks sign-in until acknowledged',
      (tester) async {
        final keyStore = InMemoryKeyStore();
        await keyStore.put(
          _handleFor(_server),
          _identityA['public_key'] as String,
        );

        var loginCalls = 0;
        final httpClient = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/version') {
            return http.Response(
              jsonEncode({
                'name': 'slim-m',
                'version': '0.10.0',
                'protocol': 1,
                'identity': _identityB,
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          if (request.method == 'POST' && request.url.path == '/auth/login') {
            loginCalls++;
            return http.Response(
              jsonEncode(_tokens.toJson()),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
        });

        final container = ProviderContainer(
          overrides: _overridesFor(keyStore: keyStore, httpClient: httpClient),
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

        await tester.enterText(find.byType(TextField).at(1), 'alice');
        await tester.enterText(find.byType(TextField).at(2), 'hunter2');
        await tester.ensureVisible(find.widgetWithText(AppButton, 'Sign in'));
        await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
        await tester.pumpAndSettle();

        expect(find.text("This server's identity changed"), findsOneWidget);
        expect(
          loginCalls,
          0,
          reason: 'a mismatch must block before any credential is sent',
        );

        await tester.ensureVisible(find.byType(Checkbox));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Checkbox));
        await tester.pump();
        final trustButton = find.text('Trust the new identity');
        await tester.ensureVisible(trustButton);
        await tester.pumpAndSettle();
        await tester.tap(trustButton);
        await tester.pumpAndSettle();

        expect(
          loginCalls,
          1,
          reason: 'acknowledging must let the sign-in proceed',
        );
        expect(
          await keyStore.read(_handleFor(_server)),
          _identityB['public_key'],
        );
      },
    );

    testWidgets(
      'a server too old to report an identity never blocks signing in',
      (tester) async {
        var loginCalls = 0;
        final httpClient = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/version') {
            return http.Response(
              jsonEncode({'name': 'slim-m', 'version': '0.6.0', 'protocol': 1}),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          if (request.method == 'POST' && request.url.path == '/auth/login') {
            loginCalls++;
            return http.Response(
              jsonEncode(_tokens.toJson()),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
        });

        final container = ProviderContainer(
          overrides: _overridesFor(
            keyStore: InMemoryKeyStore(),
            httpClient: httpClient,
          ),
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

        await tester.enterText(find.byType(TextField).at(1), 'alice');
        await tester.enterText(find.byType(TextField).at(2), 'hunter2');
        await tester.ensureVisible(find.widgetWithText(AppButton, 'Sign in'));
        await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
        await tester.pumpAndSettle();

        expect(find.text("This server's identity changed"), findsNothing);
        expect(loginCalls, 1);
      },
    );
  });
}
