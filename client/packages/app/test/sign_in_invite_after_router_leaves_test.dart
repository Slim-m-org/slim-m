// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
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
import 'package:slimm_app/src/screens/sign_in_screen.dart';
import 'package:slimm_app/src/widgets/labeled_field.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mock_app_version.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

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

Finder _field(String label) => find.descendant(
  of: find.widgetWithText(LabeledField, label),
  matching: find.byType(TextField),
);

void main() {
  setUpAll(mockAppVersion);

  testWidgets(
    'login with a pending invite clears it even after the router left sign-in',
    (tester) async {
      final redeemGate = Completer<void>();
      var redeemed = false;
      final client = MockClient((request) async {
        if (request.url.path == '/version') {
          return http.Response(
            jsonEncode({
              'name': 'Test',
              'version': '0.10.0',
              'protocol': 1,
              'identity': _identity,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && request.url.path == '/auth/login') {
          return http.Response(
            jsonEncode(_tokens.toJson()),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.url.path.contains('invite')) {
          await redeemGate.future;
          redeemed = true;
          return http.Response(
            '{}',
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      final keyStore = InMemoryKeyStore();
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(keyStore),
          serverUrlProvider.overrideWith((ref) => Uri.parse(officialServer)),
          probeApiProvider.overrideWithValue(
            (b) => SlimmApi(baseUrl: b, httpClient: client),
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
      container.read(pendingInviteProvider.notifier).state = 'CODE123';

      final session = container.read(sessionProvider);
      final changes = ChangeNotifier();
      final sub = session.changes.listen((_) => changes.notifyListeners());
      addTearDown(sub.cancel);
      final router = GoRouter(
        initialLocation: '/sign-in',
        refreshListenable: changes,
        redirect: (context, state) {
          final onJoin = state.matchedLocation == '/sign-in';
          if (session.isSignedIn && onJoin) return '/channels';
          return null;
        },
        routes: [
          GoRoute(path: '/sign-in', builder: (c, s) => const SignInScreen()),
          GoRoute(
            path: '/channels',
            builder: (c, s) => const Scaffold(body: Text('channels')),
          ),
        ],
      );

      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('I already have an account'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Username'), 'alice');
      await tester.enterText(_field('Password'), 'hunter2');
      final submit = find.widgetWithText(AppButton, 'Sign in');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      // pump frames until the router has replaced /sign-in with /channels, redeem still pending
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.text('channels'),
        findsOneWidget,
        reason: 'router left sign-in',
      );
      expect(redeemed, isFalse);

      redeemGate.complete();
      await tester.pumpAndSettle();
      expect(redeemed, isTrue);

      expect(
        container.read(pendingInviteProvider),
        isNull,
        reason: 'the spent invite must be cleared',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
