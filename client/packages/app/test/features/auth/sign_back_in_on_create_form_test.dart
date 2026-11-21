// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Someone with an account who reaches the create step anyway, as on a server
/// too old to look names up, is signed in to it when the password is theirs,
/// and is told to sign in when it is not.
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
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/whats_new/providers/whats_new_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/mock_app_version.dart';
import '../../support/sign_in_steps.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _existing = (username: 'peter', password: 'the real password');

/// A server with one account, [_existing], answering as the real one does.
class _Server {
  final calls = <String>[];

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    if (path == '/version') {
      return _json({
        'name': 'slim-m',
        'version': '0.10.0',
        'protocol': 1,
        'capabilities': ['report', 'block'],
      }, 200);
    }
    calls.add(path);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final sameName =
        (body['username'] as String).toLowerCase() == _existing.username;
    final samePassword = body['password'] == _existing.password;
    return switch (path) {
      '/auth/register' when sameName => _json({'error': 'taken'}, 409),
      '/auth/register' => _json(_tokens.toJson(), 200),
      '/auth/login' when sameName && samePassword => _json(
        _tokens.toJson(),
        200,
      ),
      _ => _json({'error': 'unauthorized'}, 401),
    };
  }
}

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

Finder _input(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens the create form on a server too old to look names up, and submits it.
Future<ProviderContainer> _createAccount(
  WidgetTester tester,
  _Server server, {
  required String username,
  required String password,
}) async {
  final client = MockClient(server.answer);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith(
        (ref) => Uri.parse('https://chat.example'),
      ),
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
  await _wait(tester);
  await chooseCreateInstead(tester);
  await tester.enterText(_input('Username'), username);
  await tester.enterText(_input('Password'), password);
  await confirmAndCreate(tester, password);
  await _wait(tester);
  return container;
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('their own username and password signs them in', (tester) async {
    final server = _Server();
    final container = await _createAccount(
      tester,
      server,
      username: 'Peter',
      password: _existing.password,
    );

    expect(server.calls, ['/auth/register', '/auth/login']);
    expect(container.read(sessionProvider).tokens?.userId, 'user-1');
    // An old account still gets its what's-new, which a new one skips.
    expect(container.read(justRegisteredProvider), isFalse);
    final toast = container.read(toastsProvider).single;
    expect(
      toast.message,
      'You already have an account here, so you are signed in to it.',
    );
    container.read(toastsProvider.notifier).dismiss(toast.id);
  });

  testWidgets('a taken username with another password points at signing in', (
    tester,
  ) async {
    final server = _Server();
    final container = await _createAccount(
      tester,
      server,
      username: 'peter',
      password: 'a password of my own',
    );

    expect(container.read(sessionProvider).tokens, isNull);
    expect(
      find.text(
        'That username is already taken. If it is yours, sign in instead.',
      ),
      findsOneWidget,
    );
    expect(container.read(toastsProvider), isEmpty);
  });

  testWidgets('a free username still creates the account, with no sign-in', (
    tester,
  ) async {
    final server = _Server();
    final container = await _createAccount(
      tester,
      server,
      username: 'dana',
      password: 'long enough pw',
    );

    expect(server.calls, ['/auth/register']);
    expect(container.read(sessionProvider).tokens?.userId, 'user-1');
    expect(container.read(justRegisteredProvider), isTrue);
  });
}
