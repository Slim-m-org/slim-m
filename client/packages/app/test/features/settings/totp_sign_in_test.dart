// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Signing in to an account that has a second factor.
///
/// The property worth a test rather than a screenshot: a 202 from `/auth/login`
/// must not be read as a session. Before the sealed [api.SignInOutcome] the
/// client would have run `TokenPair.fromJson` over the challenge body and
/// crashed on a missing field, and a nullable-token version of the same design
/// would have sailed past into an app nobody was let into.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/totp_sign_in_prompt.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _challenge = api.TotpChallenge(challenge: 'chal-1', expiresAt: 0);

String get _tokensJson => jsonEncode({
  'user_id': 'user-1',
  'access_token': 'access-1',
  'refresh_token': 'refresh-1',
  'access_expires_at': 0,
});

class _Server {
  _Server({this.verifyStatus = 200});

  final int verifyStatus;
  final List<Map<String, dynamic>> verifyBodies = [];

  MockClient get client => MockClient((request) async {
    final json = {'content-type': 'application/json'};
    if (request.url.path == '/auth/totp/verify') {
      verifyBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return verifyStatus == 200
          ? http.Response(_tokensJson, 200, headers: json)
          : http.Response(
              jsonEncode({'error': 'that code is not valid'}),
              verifyStatus,
              headers: json,
            );
    }
    return http.Response('{}', 404, headers: json);
  });
}

/// Drives [promptForTotpCode] from a button, which is how the sign-in screen
/// reaches it, and records what it resolved to.
Future<List<bool?>> _pump(WidgetTester tester, _Server server) async {
  final results = <bool?>[];
  final session = api.SessionStore();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(session),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: server.client,
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
          body: Consumer(
            builder: (context, ref, _) => AppButton(
              label: 'start',
              onPressed: () async {
                results.add(await promptForTotpCode(context, ref, _challenge));
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('start'));
  await tester.pumpAndSettle();
  return results;
}

Future<void> _submit(WidgetTester tester, String code) async {
  await tester.enterText(find.byType(TextField), code);
  await tester.pumpAndSettle();
  final button = find.widgetWithText(AppButton, 'Sign in');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  /// The 202 body is a challenge, not a token pair, and this is what proves the
  /// client reads it as one.
  test('a 202 from login is a challenge rather than a session', () async {
    final session = api.SessionStore();
    final client = MockClient((request) async {
      expect(request.url.path, '/auth/login');
      return http.Response(
        jsonEncode({'totp_challenge': 'chal-9', 'expires_at': 123}),
        202,
        headers: {'content-type': 'application/json'},
      );
    });
    final built = api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: session,
      httpClient: client,
    );
    addTearDown(built.close);

    final outcome = await built.login(
      username: 'ada',
      password: 'a-long-enough-password',
      deviceName: 'phone',
    );

    expect(outcome, isA<api.SignInChallenged>());
    expect((outcome as api.SignInChallenged).challenge.challenge, 'chal-9');
    expect(
      session.tokens,
      isNull,
      reason: 'a challenge must not leave a session behind',
    );
  });

  test('a 200 from login is still a session', () async {
    final session = api.SessionStore();
    final client = MockClient(
      (request) async => http.Response(
        _tokensJson,
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final built = api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: session,
      httpClient: client,
    );
    addTearDown(built.close);

    final outcome = await built.login(
      username: 'ada',
      password: 'a-long-enough-password',
      deviceName: 'phone',
    );
    expect(outcome, isA<api.SignedIn>());
    expect(session.tokens?.accessToken, 'access-1');
  });

  testWidgets('a correct code finishes the sign-in', (tester) async {
    final server = _Server();
    final results = await _pump(tester, server);
    expect(find.text('Enter your code'), findsOneWidget);

    await _submit(tester, '123456');

    expect(results, [true]);
    expect(server.verifyBodies.single['challenge'], 'chal-1');
    expect(server.verifyBodies.single['code'], '123456');
  });

  /// An authenticator app renders `123 456`, and somebody copying that off
  /// their own screen should not be told it is wrong.
  testWidgets('a code pasted with a space in it still works', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    await _submit(tester, '123 456');
    expect(server.verifyBodies.single['code'], '123456');
  });

  /// A wrong code leaves the challenge live server-side, so the sheet must stay
  /// open rather than dropping somebody back to the password they already got
  /// right.
  testWidgets('a wrong code keeps the sheet open to retype', (tester) async {
    final server = _Server(verifyStatus: 400);
    final results = await _pump(tester, server);
    await _submit(tester, '000000');

    expect(find.text('Enter your code'), findsOneWidget);
    expect(find.textContaining('was not accepted'), findsOneWidget);
    expect(results, isEmpty, reason: 'nothing resolved, the sheet is still up');
  });

  /// A 401 here is the challenge expiring, not the password being wrong. Saying
  /// "wrong username or password" would send somebody to retype credentials the
  /// server already accepted.
  testWidgets('an expired challenge says to start again, not that the '
      'password was wrong', (tester) async {
    final server = _Server(verifyStatus: 401);
    await _pump(tester, server);
    await _submit(tester, '123456');

    expect(find.textContaining('has expired'), findsOneWidget);
    expect(
      find.textContaining('enter your password again'),
      findsOneWidget,
      reason: 'it says to start over, which is the only move that works',
    );
    expect(find.textContaining('Wrong username'), findsNothing);
  });

  testWidgets('being locked out is said plainly', (tester) async {
    final server = _Server(verifyStatus: 429);
    await _pump(tester, server);
    await _submit(tester, '123456');
    expect(find.textContaining('Too many incorrect codes'), findsOneWidget);
  });

  /// Abandoning the sheet must leave somebody on the sign-in screen rather than
  /// part-way in: at this point the password was accepted and no session exists.
  testWidgets('dismissing the sheet does not sign anybody in', (tester) async {
    final server = _Server();
    final results = await _pump(tester, server);

    Navigator.of(tester.element(find.text('Enter your code'))).pop();
    await tester.pumpAndSettle();

    expect(results, [false]);
    expect(server.verifyBodies, isEmpty);
  });

  testWidgets(
    'the sheet has a Cancel button that closes it without a session',
    (tester) async {
      final server = _Server();
      final results = await _pump(tester, server);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your code'), findsNothing);
      expect(results, [false]);
      expect(server.verifyBodies, isEmpty);
    },
  );
}
