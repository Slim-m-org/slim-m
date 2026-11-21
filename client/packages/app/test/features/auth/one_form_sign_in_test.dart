// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One form signs in and creates accounts (decision 0130): the server says
/// whether the username exists, so nobody makes a second account by typing
/// their own details into a form that was guessing they were new.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/features/auth/widgets/server_identity_confirmation.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/mock_app_version.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

final _address = Uri.parse('https://chat.example');

/// A Space with one account, `rbsheeh`, answering as the real server does.
class _Space {
  _Space({this.checksNames = true});

  /// False for a server from before the username check.
  final bool checksNames;
  final calls = <String>[];

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    if (path == '/version') {
      return _json({
        'name': 'slim-m',
        'space_name': 'Hearth',
        'version': '0.134.0',
        'protocol': 1,
        'capabilities': ['report', 'block', if (checksNames) 'username_check'],
      });
    }
    calls.add(path);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final known = (body['username'] as String).toLowerCase() == 'rbsheeh';
    return switch (path) {
      '/auth/username/check' when checksNames => _json({'exists': known}),
      '/auth/username/check' => _json({'error': 'not found'}, 404),
      '/auth/login' when known && body['password'] == 'the real password' =>
        _json(_tokens.toJson()),
      '/auth/login' => _json({'error': 'unauthorized'}, 401),
      '/auth/register' when known => _json({'error': 'taken'}, 409),
      '/auth/register' => _json(_tokens.toJson()),
      _ => _json({'error': 'not found'}, 404),
    };
  }
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

Finder _input(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

Finder _button(String label) => find.widgetWithText(AppButton, label);

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The form as a fresh install reaches it: a Space never signed in to before.
Future<ProviderContainer> _open(WidgetTester tester, _Space space) async {
  final client = MockClient(space.answer);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => _address),
      firstContactServersProvider.overrideWith(
        (ref) => {identityHandleFor(_address)},
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
  tester.view.physicalSize = const Size(900, 1800);
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
  return container;
}

Future<void> _continueAs(
  WidgetTester tester,
  String username,
  String password,
) async {
  await tester.enterText(_input('Username'), username);
  await tester.enterText(_input('Password'), password);
  await tester.tap(_button('Continue'));
  await _wait(tester);
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('a fresh install opens on one form, not on creating an account', (
    tester,
  ) async {
    await _open(tester, _Space());

    expect(find.text('Sign in or create an account'), findsOneWidget);
    expect(_input('Confirm password'), findsNothing);
    expect(_button('Create an account instead'), findsOneWidget);
  });

  testWidgets('a username with an account signs in', (tester) async {
    final space = _Space();
    final container = await _open(tester, space);

    await _continueAs(tester, 'rbsheeh', 'the real password');

    expect(space.calls, ['/auth/username/check', '/auth/login']);
    expect(container.read(sessionProvider).tokens?.userId, 'user-1');
  });

  testWidgets('a misremembered username is named before anything is created', (
    tester,
  ) async {
    final space = _Space();
    final container = await _open(tester, space);

    await _continueAs(tester, 'rbsheehy', 'the real password');

    // The password stayed here: only the name was asked about.
    expect(space.calls, ['/auth/username/check']);
    expect(container.read(sessionProvider).tokens, isNull);
    expect(find.text('Create an account'), findsOneWidget);
    expect(
      find.text(
        'There is no account named rbsheehy on Hearth. Create it here, or '
        'go back if you already have one.',
      ),
      findsOneWidget,
    );

    await tester.tap(_button('I already have an account'));
    await _wait(tester);
    await _continueAs(tester, 'rbsheeh', 'the real password');

    expect(space.calls, [
      '/auth/username/check',
      '/auth/username/check',
      '/auth/login',
    ]);
    expect(container.read(sessionProvider).tokens?.userId, 'user-1');
  });

  testWidgets('a new username creates the account once the password is '
      'entered twice', (tester) async {
    final space = _Space();
    final container = await _open(tester, space);
    await _continueAs(tester, 'dana', 'long enough pw');

    await tester.enterText(_input('Confirm password'), 'long enough pv');
    await tester.tap(_button('Create account'));
    await _wait(tester);

    expect(find.text('The passwords do not match.'), findsOneWidget);
    expect(space.calls, ['/auth/username/check']);

    await tester.enterText(_input('Confirm password'), 'long enough pw');
    await tester.tap(_button('Create account'));
    await _wait(tester);

    expect(space.calls, ['/auth/username/check', '/auth/register']);
    expect(container.read(sessionProvider).tokens?.userId, 'user-1');
  });

  testWidgets('a wrong password names the account it was wrong for', (
    tester,
  ) async {
    final space = _Space();
    final container = await _open(tester, space);

    await _continueAs(tester, 'rbsheeh', 'not the password');

    expect(container.read(sessionProvider).tokens, isNull);
    expect(
      find.text(
        'Wrong password for rbsheeh. New here? That username is taken.',
      ),
      findsOneWidget,
    );
    expect(_input('Confirm password'), findsNothing);
  });

  testWidgets('editing the name on the create step drops the notice about '
      'the old one', (tester) async {
    await _open(tester, _Space());
    await _continueAs(tester, 'rbsheehy', 'the real password');

    await tester.enterText(_input('Username'), 'riley');
    await _wait(tester);

    expect(find.textContaining('There is no account named'), findsNothing);
  });

  group('a server from before the username check', () {
    testWidgets('signs in as it always did', (tester) async {
      final space = _Space(checksNames: false);
      final container = await _open(tester, space);

      await _continueAs(tester, 'rbsheeh', 'the real password');

      expect(space.calls, ['/auth/login']);
      expect(container.read(sessionProvider).tokens?.userId, 'user-1');
    });

    testWidgets('keeps the way across to creating an account', (tester) async {
      final space = _Space(checksNames: false);
      await _open(tester, space);

      await _continueAs(tester, 'dana', 'long enough pw');

      expect(find.text('Wrong username or password.'), findsOneWidget);

      await tester.tap(_button('Create an account instead'));
      await _wait(tester);

      expect(find.text('Create an account'), findsOneWidget);
      expect(find.textContaining('There is no account named'), findsNothing);
    });
  });
}
