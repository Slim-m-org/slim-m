// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sign-in says where it is about to connect, and asks for an out-of-band
/// check only where one can be answered.
///
/// The identity chip used to live inside the branch that renders the address
/// field, so the official-server path - the most common way in, and the one
/// that deliberately hides that field - named no destination anywhere on the
/// screen. And `_submit` confirmed identity without `silentFirstConnect`, so
/// signing in to the compiled-in official address from a fresh install put up
/// the fingerprint screen, which asks you to read a code to an operator that,
/// for that address, is the same party that published the app.
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
import 'package:slimm_app/src/widgets/labeled_field.dart';
import 'package:slimm_app/src/features/auth/widgets/server_identity_confirmation.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../support/mock_app_version.dart';

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

/// Answers `/version` with an identity and counts the logins, so a test can
/// tell "the fingerprint screen blocked this" from "it signed straight in".
http.Client _client({
  required void Function() onLogin,
  bool withIdentity = true,
}) => MockClient((request) async {
  if (request.method == 'GET' && request.url.path == '/version') {
    return http.Response(
      jsonEncode({
        'name': 'Test Space',
        'version': '0.10.0',
        'protocol': 1,
        if (withIdentity) 'identity': _identity,
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
  if (request.method == 'POST' && request.url.path == '/auth/login') {
    onLogin();
    return http.Response(
      jsonEncode(_tokens.toJson()),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
  return http.Response('{}', 200);
});

Future<KeyStore> _pump(
  WidgetTester tester, {
  required Uri server,
  required http.Client client,
}) async {
  final keyStore = InMemoryKeyStore();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keyStore),
      serverUrlProvider.overrideWith((ref) => server),
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
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const SignInScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return keyStore;
}

/// The box under the field named [label]: the name is drawn above the
/// control, not inside it, so a text-in-field finder never sees it.
Finder _field(String label) => find.descendant(
  of: find.widgetWithText(LabeledField, label),
  matching: find.byType(TextField),
);

/// Fills the credentials and submits. The address field is absent on the
/// official path, so the fields are found by their label rather than by index.
Future<void> _signIn(WidgetTester tester) async {
  await tester.enterText(_field('Username'), 'alice');
  await tester.enterText(_field('Password'), 'hunter2');
  final submit = find.widgetWithText(AppButton, 'Sign in');
  await tester.ensureVisible(submit);
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('the official server names its host with no address field', (
    tester,
  ) async {
    await _pump(
      tester,
      server: Uri.parse(officialServer),
      client: _client(onLogin: () {}),
    );

    expect(
      _field('Server'),
      findsNothing,
      reason: 'the address is not a decision on this path',
    );
    expect(
      find.textContaining(Uri.parse(officialServer).host),
      findsOneWidget,
      reason: 'the screen must still say where it is connecting',
    );
  });

  testWidgets('a server that has not answered yet still names its host', (
    tester,
  ) async {
    // No identity and no name to build a chip from: the quieter line carries it.
    await _pump(
      tester,
      server: Uri.parse('https://chat.example'),
      client: MockClient((request) async => http.Response('', 500)),
    );

    expect(find.textContaining('chat.example'), findsWidgets);
  });

  testWidgets('signing in to the official server asks for no fingerprint', (
    tester,
  ) async {
    var logins = 0;
    final keyStore = await _pump(
      tester,
      server: Uri.parse(officialServer),
      client: _client(onLogin: () => logins++),
    );

    await _signIn(tester);

    expect(
      find.text('Confirm this server'),
      findsNothing,
      reason: 'there is no separate operator to read this code to',
    );
    expect(logins, 1, reason: 'the sign-in must go straight through');
    expect(
      await keyStore.read(identityHandleFor(Uri.parse(officialServer))),
      _identity['public_key'],
      reason: 'silent still means pinned: a later change must be caught',
    );
  });

  testWidgets('signing in to someone else\'s server still asks, and says how', (
    tester,
  ) async {
    var logins = 0;
    await _pump(
      tester,
      server: Uri.parse('https://chat.example'),
      client: _client(onLogin: () => logins++),
    );

    await _signIn(tester);

    expect(find.text('Confirm this server'), findsOneWidget);
    expect(logins, 0, reason: 'no credential before the code is confirmed');
    expect(
      find.textContaining('chat.example'),
      findsWidgets,
      reason: 'the screen names whose server to ask',
    );
    expect(
      find.textContaining('server log'),
      findsOneWidget,
      reason: 'where that operator finds their own copy of the code',
    );
    expect(find.text('Copy this code'), findsOneWidget);
  });
}
