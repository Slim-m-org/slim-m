// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the sign-in form says before and after a failed attempt: an empty
/// field is caught before anything is sent, an error goes once the field it
/// is about is edited, and an offline device is told about its own
/// connection rather than the Space's.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/providers/browser_reach.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/features/auth/widgets/server_identity_confirmation.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/mock_app_version.dart';

const _server = 'https://chat.example';
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

Finder _input(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

/// The Space answers its probe; whether sign-in itself gets through is [login].
Future<List<String>> _open(
  WidgetTester tester, {
  required Future<http.Response> Function() login,
  bool online = true,
  Future<void>? probeAnswers,
}) async {
  final sent = <String>[];
  final keyStore = InMemoryKeyStore();
  await keyStore.put(identityHandleFor(Uri.parse(_server)), _key);
  final probe = MockClient((request) async {
    sent.add(request.url.path);
    await probeAnswers;
    return http.Response(
      jsonEncode({
        'name': 'slim-m',
        'version': '0.10.0',
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
  final api = MockClient((request) async {
    sent.add(request.url.path);
    return login();
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keyStore),
      serverUrlProvider.overrideWith((ref) => Uri.parse(_server)),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: probe),
      ),
      apiProvider.overrideWith((ref) {
        final client = SlimmApi(
          baseUrl: ref.watch(serverUrlProvider),
          session: ref.watch(sessionProvider),
          httpClient: api,
        );
        ref.onDispose(client.close);
        return client;
      }),
      browserReachProbeProvider.overrideWithValue((server) async => false),
      browserOnlineProvider.overrideWithValue(() => online),
    ],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
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
  await pumpFrames(tester);
  return sent;
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
  await pumpFrames(tester);
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('an empty username or password is named before anything is '
      'sent', (tester) async {
    final sent = await _open(
      tester,
      login: () async => http.Response('{"error":"bad credentials"}', 401),
    );
    sent.clear();

    await _submit(tester);
    expect(find.text('Enter your username.'), findsOne);
    expect(find.textContaining('Wrong username'), findsNothing);

    await tester.enterText(_input('Username'), 'ava');
    await _submit(tester);
    expect(find.text('Enter your password.'), findsOne);
    expect(sent, isEmpty);
  });

  testWidgets('a wrong password error goes once either field is edited', (
    tester,
  ) async {
    await _open(
      tester,
      login: () async => http.Response('{"error":"bad credentials"}', 401),
    );
    await tester.enterText(_input('Username'), 'ava');
    await tester.enterText(_input('Password'), 'long enough pw');
    await _submit(tester);
    expect(find.textContaining('Wrong username or password'), findsOne);

    await tester.enterText(_input('Password'), 'long enough pw2');
    await tester.pump();
    expect(find.textContaining('Wrong username or password'), findsNothing);
  });

  testWidgets('offline, the error is about this device and the Space is no '
      'longer shown as confirmed', (tester) async {
    await _open(
      tester,
      online: false,
      login: () async => throw http.ClientException('Failed to fetch'),
    );
    expect(find.text('Confirmed'), findsOne);
    await tester.enterText(_input('Username'), 'ava');
    await tester.enterText(_input('Password'), 'long enough pw');
    await _submit(tester);

    expect(find.textContaining('This device is offline'), findsOne);
    expect(find.textContaining('Could not reach this Space'), findsNothing);
    expect(find.text('Confirmed'), findsNothing);
  });

  testWidgets('the form does not move when the Space answers its probe', (
    tester,
  ) async {
    final answer = Completer<void>();
    await _open(
      tester,
      probeAnswers: answer.future,
      login: () async => http.Response('{}', 401),
    );
    expect(find.text('Connecting to chat.example'), findsOne);
    final before = tester.getTopLeft(_input('Username')).dy;

    answer.complete();
    await pumpFrames(tester);

    expect(find.text('Confirmed'), findsOne);
    expect(tester.getTopLeft(_input('Username')).dy, before);
  });
}
