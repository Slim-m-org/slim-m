// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Creating an account goes in order: the server answers, an invite-only
/// Space checks the code, and only then are a username and password asked
/// for. Signing in to an existing account does not wait on either.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/invite_code_check.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/mock_app_version.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

Map<String, Object?> _version({required bool invitesOnly}) => {
  'name': 'slim-m',
  'version': '0.131.0',
  'protocol': 1,
  'claimed': true,
  'invite_required': invitesOnly,
  'capabilities': ['report', 'block'],
};

const _usable = {
  'usable': true,
  'community': {
    'name': 'Home',
    'member_count': 3,
    'invited_by': 'Nia',
    'uses_remaining': null,
    'expires_at': null,
  },
};

/// What the fake server was sent, for the assertions to read.
class _Server {
  final registered = <Map<String, Object?>>[];
  final probed = <String>[];
}

Future<_Server> _pump(
  WidgetTester tester, {
  bool invitesOnly = true,
  bool creating = true,
  bool reachable = true,
  String? pendingInvite,
  Future<void>? versionAnswer,
}) async {
  final server = _Server();
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/version') {
      server.probed.add(request.url.host);
      await versionAnswer;
      if (!reachable) throw http.ClientException('connection refused');
      return _json(_version(invitesOnly: invitesOnly));
    }
    if (path == '/invites/GOOD/check') return _json(_usable);
    if (path.endsWith('/check')) return _json(const {'usable': false});
    if (path == '/auth/register') {
      server.registered.add(jsonDecode(request.body) as Map<String, Object?>);
      return _json(_tokens.toJson());
    }
    return _json(const {});
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith(
        (ref) => Uri.parse('https://chat.example'),
      ),
      assumeNewAccountProvider.overrideWith((ref) => creating),
      pendingInviteProvider.overrideWith((ref) => pendingInvite),
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
  tester.view.physicalSize = const Size(1280, 1100);
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
  return server;
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

Finder _input(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

Finder _button(String label) => find.widgetWithText(AppButton, label);

Future<void> _continueWith(WidgetTester tester, String code) async {
  await tester.enterText(_input('Invite code'), code);
  await tester.tap(_button('Continue'));
  await pumpFrames(tester);
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('an invite-only Space asks for the code before any account '
      'field, and only a code that checks out opens them', (tester) async {
    final server = await _pump(tester);

    expect(_input('Invite code'), findsOneWidget);
    expect(_input('Username'), findsNothing);
    expect(_input('Password'), findsNothing);
    expect(_button('Create account'), findsNothing);

    await _continueWith(tester, 'SPENT');
    expect(find.text(inviteUnusable), findsOneWidget);
    expect(_input('Username'), findsNothing);

    await _continueWith(tester, 'GOOD');
    expect(find.text('Invite accepted.'), findsOneWidget);
    expect(_input('Username'), findsOneWidget);
    expect(_input('Password'), findsOneWidget);

    await tester.enterText(_input('Username'), 'dana');
    await tester.enterText(_input('Password'), 'long enough pw');
    await tester.tap(_button('Create account'));
    await waitUntil(tester, () => server.registered.isNotEmpty);
    expect(server.registered.single['invite_code'], 'GOOD');
  });

  testWidgets('changing a code that checked out closes the account fields '
      'again', (tester) async {
    await _pump(tester);
    await _continueWith(tester, 'GOOD');
    expect(_input('Username'), findsOneWidget);

    await tester.enterText(_input('Invite code'), 'GOODX');
    await pumpFrames(tester);
    expect(_input('Username'), findsNothing);
    expect(_button('Continue'), findsOneWidget);
  });

  testWidgets('a pasted invite link fills in the server and the code', (
    tester,
  ) async {
    final server = await _pump(tester);
    await tester.enterText(
      _input('Invite code'),
      'https://other.example/invite/GOOD',
    );
    await tester.pump(const Duration(seconds: 1));
    await pumpFrames(tester);

    final fields = tester.widgetList<AppInput>(_input('Server'));
    expect(fields.single.controller!.text, 'https://other.example');
    final code = tester.widget<AppInput>(_input('Invite code'));
    expect(code.controller!.text, 'GOOD');
    expect(server.probed, contains('other.example'));
  });

  testWidgets('while the server has not answered, no account field shows', (
    tester,
  ) async {
    final answer = Completer<void>();
    await _pump(tester, invitesOnly: false, versionAnswer: answer.future);

    expect(_input('Username'), findsNothing);
    expect(_button('Continue'), findsOneWidget);

    answer.complete();
    await pumpFrames(tester);
    expect(_input('Invite code'), findsNothing);
    expect(_input('Username'), findsOneWidget);
    expect(_button('Create account'), findsOneWidget);
  });

  testWidgets('a server that cannot be reached says so under the address and '
      'asks for nothing else', (tester) async {
    await _pump(tester, reachable: false);

    final field = tester.widget<AppInput>(_input('Server'));
    expect(field.errorText, contains('Could not reach this Space'));
    expect(_input('Invite code'), findsNothing);
    expect(_input('Username'), findsNothing);
  });

  testWidgets('a public http address that answers opens no account field and '
      'says why under Server', (tester) async {
    await _pump(tester, invitesOnly: false);
    expect(_input('Username'), findsOneWidget);

    await tester.enterText(_input('Server'), 'http://chat.example.com');
    await tester.pump(const Duration(seconds: 1));
    await pumpFrames(tester);
    expect(_input('Username'), findsNothing);

    await tester.tap(_button('Continue'));
    await tester.pump(const Duration(seconds: 1));
    await pumpFrames(tester);
    expect(_input('Username'), findsNothing);
    expect(
      tester.widget<AppInput>(_input('Server')).errorText,
      startsWith('Use https for a Space on the internet.'),
    );
  });

  testWidgets('editing the address clears the error under it before the '
      'next answer opens the account fields', (tester) async {
    await _pump(tester, invitesOnly: false);
    await tester.enterText(_input('Server'), 'http://chat.example.com');
    await tester.pump();
    await tester.tap(_button('Continue'));
    await pumpFrames(tester);
    expect(tester.widget<AppInput>(_input('Server')).errorText, isNotNull);

    await tester.enterText(_input('Server'), 'https://chat.example.com');
    await tester.pump(const Duration(seconds: 1));
    await pumpFrames(tester);
    expect(tester.widget<AppInput>(_input('Server')).errorText, isNull);
    expect(_input('Username'), findsOneWidget);
  });

  testWidgets('a failed answer to a half-typed address stays quiet until '
      'Continue', (tester) async {
    await _pump(tester, reachable: false);
    await tester.enterText(_input('Server'), 'chat.exa');
    await tester.pump(const Duration(seconds: 1));
    await pumpFrames(tester);

    expect(tester.widget<AppInput>(_input('Server')).errorText, isNull);
    expect(find.text('Connecting to chat.exa'), findsOneWidget);

    await tester.tap(_button('Continue'));
    await pumpFrames(tester);
    expect(
      tester.widget<AppInput>(_input('Server')).errorText,
      contains('Could not reach this Space'),
    );
  });

  testWidgets('leaving the address field says why it failed', (tester) async {
    await _pump(tester, reachable: false);
    await tester.enterText(_input('Server'), 'chat.exa');
    await tester.pump(const Duration(seconds: 1));
    await pumpFrames(tester);
    expect(tester.widget<AppInput>(_input('Server')).errorText, isNull);

    FocusManager.instance.primaryFocus?.unfocus();
    await pumpFrames(tester, frames: 2);
    expect(
      tester.widget<AppInput>(_input('Server')).errorText,
      contains('Could not reach this Space'),
    );
  });

  testWidgets('signing in to an existing account does not wait on the server', (
    tester,
  ) async {
    final answer = Completer<void>();
    await _pump(tester, creating: false, versionAnswer: answer.future);

    expect(_input('Username'), findsOneWidget);
    expect(_input('Invite code'), findsNothing);
    expect(_button('Sign in'), findsOneWidget);
    answer.complete();
    await pumpFrames(tester);
  });

  testWidgets('a code checked during onboarding counts on its own server', (
    tester,
  ) async {
    final server = await _pump(tester, pendingInvite: 'GOOD');

    expect(find.text('Invite accepted.'), findsOneWidget);
    await tester.enterText(_input('Username'), 'dana');
    await tester.enterText(_input('Password'), 'long enough pw');
    await tester.tap(_button('Create account'));
    await waitUntil(tester, () => server.registered.isNotEmpty);
    expect(server.registered.single['invite_code'], 'GOOD');
  });
}
