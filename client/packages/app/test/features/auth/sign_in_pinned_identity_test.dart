// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Signing in to a pinned Space sends no password until the address has
/// answered as that Space: an error page, no answer, or a key it cannot prove
/// stops the sign-in before the password leaves.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/mock_app_version.dart';

const _server = 'https://chat.example';
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

Finder _field(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

final _version = {
  'name': 'slim-m',
  'version': '0.90.0',
  'protocol': 1,
  'identity': {
    'public_key': _key,
    'fingerprint': 'deadbeefcafebabefeedface1337d00d',
    'fingerprint_groups': ['dead', 'beef', 'cafe', 'babe'],
    'color_strip': [0, 1, 2, 3],
  },
};

/// A pinned Space whose `/version` answers with [version], counting sign-ins.
Future<({ProviderContainer container, List<String> logins})> _pinned(
  WidgetTester tester,
  Future<http.Response> Function(http.Request request) version,
) async {
  final logins = <String>[];
  final client = MockClient((request) async {
    switch (request.url.path) {
      case '/version':
        return version(request);
      case '/identity/proof':
        return _json({
          'public_key': _key,
          'signature': base64.encode(List<int>.filled(64, 7)),
        });
      case '/auth/login':
        logins.add(request.body);
        return _json(
          const TokenPair(
            userId: 'user-1',
            accessToken: 'access-1',
            refreshToken: 'refresh-1',
            accessExpiresAt: 0,
          ).toJson(),
        );
    }
    return _json({'exists': true});
  });
  final keyStore = InMemoryKeyStore();
  await keyStore.put('server_identity:$_server', _key);
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
  container.read(chosenServerProvider.notifier).restore(Uri.parse(_server));
  tester.view.physicalSize = const Size(1280, 800);
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
  await pumpFrames(tester, frames: 30);
  return (container: container, logins: logins);
}

Future<void> _submit(WidgetTester tester) async {
  await tester.enterText(_field('Username'), 'ava');
  await tester.enterText(_field('Password'), 'long enough pw');
  await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
  await pumpFrames(tester, frames: 60);
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('a pinned address answering /version with a 404 page is not '
      'a slim-m server and gets no password', (tester) async {
    final rig = await _pinned(
      tester,
      (_) async => http.Response('<html>Not found</html>', 404),
    );

    await _submit(tester);

    expect(rig.logins, isEmpty);
    expect(rig.container.read(sessionProvider).tokens, isNull);
  });

  for (final (name, status, body) in [
    ('a 500', 500, ''),
    ('a 503', 503, '{"error":"down"}'),
    ('a 403', 403, '{"error":"no"}'),
  ]) {
    testWidgets('a pinned address answering /version with $name shows the '
        'changed-identity step and sends no password', (tester) async {
      final rig = await _pinned(
        tester,
        (_) async => http.Response(body, status),
      );

      await _submit(tester);
      await waitUntil(
        tester,
        () => find.textContaining('no longer proves').evaluate().isNotEmpty,
      );

      expect(rig.logins, isEmpty);
    });
  }

  testWidgets('a pinned address that does not answer sends no password', (
    tester,
  ) async {
    final rig = await _pinned(
      tester,
      (_) async => throw http.ClientException('connection refused'),
    );

    await _submit(tester);

    expect(rig.logins, isEmpty);
    expect(rig.container.read(sessionProvider).tokens, isNull);
  });

  testWidgets('a pinned key replayed without a valid proof sends no password', (
    tester,
  ) async {
    final rig = await _pinned(tester, (_) async => _json(_version));

    await _submit(tester);
    await waitUntil(
      tester,
      () => find.textContaining('no longer proves').evaluate().isNotEmpty,
    );

    expect(rig.logins, isEmpty);
  });
}
