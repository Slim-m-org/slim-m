// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The capability handshake and the acknowledge modal on the sign-in screen.
///
/// slim-m's safety model is manual reporting plus blocking and nothing else,
/// so a server offering neither leaves a member with no recourse. This checks
/// that creating an account says so in a modal first, that it never says it
/// about a server that has not been asked or is too old to answer, that
/// signing in never asks, and that the person can always continue or back out.
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
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/mock_app_version.dart';

/// Everything `/version` carries that is not this test's subject.
Map<String, Object?> _version(Object? capabilities) => {
  'name': 'slim-m',
  'version': '0.17.0',
  'protocol': 1,
  'push_enabled': true,
  if (capabilities != null) 'capabilities': capabilities,
};

/// Pumps the sign-in screen against a server answering [body] on `/version`,
/// and returns the paths the server was asked for.
Future<List<String>> pumpAgainst(
  WidgetTester tester,
  Map<String, Object?>? body,
) async {
  final requested = <String>[];
  final httpClient = MockClient((request) async {
    requested.add(request.url.path);
    if (request.method == 'GET' && request.url.path == '/version') {
      if (body == null) throw http.ClientException('connection refused');
      return http.Response(
        jsonEncode(body),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 200);
  });

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
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
  await tester.pumpAndSettle();
  return requested;
}

Finder _input(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

Future<void> _fillAndSubmit(WidgetTester tester, String button) async {
  await tester.enterText(_input('Username'), 'dana');
  await tester.enterText(_input('Password'), 'long enough pw');
  await tester.tap(find.widgetWithText(AppButton, button));
  await pumpFrames(tester, frames: 30);
}

/// Switches to creating an account and submits the form.
Future<void> _createAccount(WidgetTester tester) async {
  await tester.tap(find.text('Create an account instead'));
  await pumpFrames(tester);
  await _fillAndSubmit(tester, 'Create account');
}

final _modalTitle = find.text('Before you create an account');
final _missingNotice = find.textContaining('offers no way to');
final _unknownNotice = find.textContaining('too old to say whether it offers');
final _adminNotice = find.textContaining('first account becomes');

void main() {
  setUpAll(mockAppVersion);

  testWidgets('a server advertising both report and block asks nothing', (
    tester,
  ) async {
    final requested = await pumpAgainst(tester, _version(['report', 'block']));
    await _createAccount(tester);
    expect(_modalTitle, findsNothing);
    expect(requested, contains('/auth/register'));
  });

  testWidgets('a server advertising neither names both, and what it costs', (
    tester,
  ) async {
    await pumpAgainst(tester, _version(<String>[]));
    await _createAccount(tester);
    expect(_modalTitle, findsOneWidget);
    final text = tester.widget<Text>(_missingNotice).data!;
    expect(text, contains('report a message'));
    expect(text, contains('block anyone'));
    expect(
      text,
      contains('but you can still join'),
      reason: 'the modal informs; it never blocks',
    );
  });

  testWidgets('a server advertising only reporting names blocking alone', (
    tester,
  ) async {
    await pumpAgainst(tester, _version(['report']));
    await _createAccount(tester);
    final text = tester.widget<Text>(_missingNotice).data!;
    expect(text, contains('block anyone'));
    expect(
      text,
      isNot(contains('report a message')),
      reason: 'naming a tool the server does have would be wrong',
    );
  });

  testWidgets('a server too old to advertise anything is not accused', (
    tester,
  ) async {
    await pumpAgainst(tester, _version(null));
    await _createAccount(tester);
    expect(
      _missingNotice,
      findsNothing,
      reason: 'silence from an old server is unknown, not "has neither"',
    );
    expect(_unknownNotice, findsOneWidget);
  });

  testWidgets('a server that cannot be reached is not accused either', (
    tester,
  ) async {
    await pumpAgainst(tester, null);
    await _createAccount(tester);
    expect(_modalTitle, findsNothing);
    expect(_missingNotice, findsNothing);
    expect(_unknownNotice, findsNothing);
  });

  testWidgets('a capability list that is not a list reads as unknown', (
    tester,
  ) async {
    await pumpAgainst(tester, _version('report,block'));
    await _createAccount(tester);
    expect(_missingNotice, findsNothing);
    expect(_unknownNotice, findsOneWidget);
  });

  testWidgets('an unclaimed Space lists the administrator warning with the '
      'safety one, in one modal', (tester) async {
    await pumpAgainst(tester, {..._version(<String>[]), 'claimed': false});
    await _fillAndSubmit(tester, 'Create account');
    expect(_modalTitle, findsOneWidget);
    expect(_adminNotice, findsOneWidget);
    expect(_missingNotice, findsOneWidget);
    expect(
      find.text('Continue').evaluate().length +
          find.text('Cancel').evaluate().length,
      2,
    );
  });

  testWidgets('an unclaimed Space with every tool says only the admin line', (
    tester,
  ) async {
    await pumpAgainst(tester, {
      ..._version(['report', 'block']),
      'claimed': false,
    });
    await _fillAndSubmit(tester, 'Create account');
    expect(_adminNotice, findsOneWidget);
    expect(_missingNotice, findsNothing);
    expect(_unknownNotice, findsNothing);
  });

  testWidgets('Cancel sends nothing and leaves the form as it was', (
    tester,
  ) async {
    final requested = await pumpAgainst(tester, _version(<String>[]));
    await _createAccount(tester);
    await tester.tap(find.text('Cancel'));
    await pumpFrames(tester, frames: 30);
    expect(_modalTitle, findsNothing);
    expect(requested, isNot(contains('/auth/register')));
    expect(
      tester.widget<AppInput>(_input('Username')).controller!.text,
      'dana',
    );
  });

  testWidgets('Continue creates the account', (tester) async {
    final requested = await pumpAgainst(tester, _version(<String>[]));
    await _createAccount(tester);
    await tester.tap(find.text('Continue'));
    await pumpFrames(tester, frames: 30);
    expect(requested, contains('/auth/register'));
  });

  testWidgets('signing in never shows the modal, whatever the server lacks', (
    tester,
  ) async {
    final requested = await pumpAgainst(tester, _version(<String>[]));
    await _fillAndSubmit(tester, 'Sign in');
    expect(_modalTitle, findsNothing);
    expect(requested, contains('/auth/login'));
  });

  testWidgets('the safety lines are no longer inline in the form', (
    tester,
  ) async {
    await pumpAgainst(tester, _version(<String>[]));
    expect(_missingNotice, findsNothing);
    expect(_unknownNotice, findsNothing);
  });
}
