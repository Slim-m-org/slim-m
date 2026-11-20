// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Redeem an invite: a failure sits under the field it is about, the way
/// sign-in shows it, and never as a boxed banner in the dialog.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/invite_code_check.dart';
import 'package:slimm_app/src/features/auth/screens/invite_dialog.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';

Future<void> _pump(
  WidgetTester tester, {
  Object? checkBody = const {'usable': false},
  int checkStatus = 200,
  bool unreachable = false,
  ({Uri server, String code})? initial,
  bool fullScreen = false,
}) async {
  tester.view.physicalSize = fullScreen
      ? const Size(390, 844)
      : const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = MockClient((request) async {
    if (unreachable) throw Exception('connection refused');
    return http.Response(
      jsonEncode(checkBody),
      checkStatus,
      headers: const {'content-type': 'application/json'},
    );
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        probeApiProvider.overrideWithValue(
          (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: fullScreen
            ? InviteDialog(initial: initial, fullScreen: true)
            : Scaffold(body: InviteDialog(initial: initial)),
      ),
    ),
  );
  await pumpFrames(tester);
}

Finder _field(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

String? _errorUnder(WidgetTester tester, String label) =>
    tester.widget<AppInput>(_field(label)).errorText;

Finder _banner() => find.byWidgetPredicate((w) => w is AppErrorState);

Future<void> _continueWith(
  WidgetTester tester, {
  required String server,
  required String code,
}) async {
  await tester.enterText(_field('Server'), server);
  await tester.enterText(_field('Invite code'), code);
  await _acceptAndContinue(tester);
}

/// Pumps until the mocked reply has been answered on screen; the reply resolves inside the pumps.
Future<void> _pumpUntil(WidgetTester tester, bool Function() shown) async {
  for (var i = 0; i < 100 && !shown(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(shown(), isTrue);
}

Future<void> _acceptAndContinue(WidgetTester tester) async {
  await tester.tap(find.text('I accept the terms of use for this Space.'));
  await tester.pump();
  await tester.tap(find.text('Continue'));
  await pumpFrames(tester);
}

void main() {
  testWidgets('a bad address sits under the Server field', (tester) async {
    await _pump(tester);
    await _continueWith(tester, server: 'not a url', code: 'CODE1');

    expect(
      _errorUnder(tester, 'Server'),
      'That does not look like a server address.',
    );
    expect(_errorUnder(tester, 'Invite code'), isNull);
    expect(_banner(), findsNothing);
  });

  testWidgets('an address that does not answer sits under the Server field', (
    tester,
  ) async {
    await _pump(tester, unreachable: true);
    await _continueWith(tester, server: 'https://chat.example', code: 'CODE1');
    await _pumpUntil(tester, () => _errorUnder(tester, 'Server') != null);

    expect(_errorUnder(tester, 'Server'), 'Could not reach that server.');
    expect(_banner(), findsNothing);
  });

  testWidgets('an empty code is refused under the code field, unasked', (
    tester,
  ) async {
    await _pump(tester);
    await _continueWith(tester, server: 'https://chat.example', code: '  ');

    expect(
      _errorUnder(tester, 'Invite code'),
      'Enter the invite code you were sent.',
    );
    expect(_errorUnder(tester, 'Server'), isNull);
  });

  testWidgets('an unusable code sits under the code field', (tester) async {
    await _pump(tester);
    await _continueWith(
      tester,
      server: 'https://chat.example',
      code: 'DEADCODE1',
    );
    await _pumpUntil(tester, () => _errorUnder(tester, 'Invite code') != null);

    expect(_errorUnder(tester, 'Invite code'), contains('not usable'));
    expect(_errorUnder(tester, 'Server'), isNull);
    expect(_banner(), findsNothing);
  });

  testWidgets('a web address typed as the code sits under the code field', (
    tester,
  ) async {
    await _pump(tester);
    await _continueWith(
      tester,
      server: 'https://chat.example',
      code: 'https://example.com/page',
    );

    expect(_errorUnder(tester, 'Invite code'), contains('web address'));
    expect(_banner(), findsNothing);
  });

  testWidgets('a refusal no field owns is plain text above the buttons', (
    tester,
  ) async {
    await _pump(
      tester,
      checkBody: const {'error': 'internal error'},
      checkStatus: 500,
    );
    await _continueWith(tester, server: 'https://chat.example', code: 'CODE1');
    await _pumpUntil(
      tester,
      () =>
          find.textContaining('The server refused that').evaluate().isNotEmpty,
    );

    expect(_errorUnder(tester, 'Server'), isNull);
    expect(_errorUnder(tester, 'Invite code'), isNull);
    expect(_banner(), findsNothing);
    expect(
      tester.getTopLeft(find.textContaining('The server refused that')).dy,
      lessThan(tester.getTopLeft(find.text('Continue')).dy),
    );
  });

  testWidgets('a reply that is not an invite check is said above the buttons', (
    tester,
  ) async {
    await _pump(tester, checkBody: const ['not', 'a', 'map']);
    await _continueWith(tester, server: 'https://chat.example', code: 'CODE1');
    await _pumpUntil(
      tester,
      () => find.text(inviteNotFromASpace).evaluate().isNotEmpty,
    );

    expect(_banner(), findsNothing);
    expect(
      tester.widget<AppButton>(find.widgetWithText(AppButton, 'Continue')).busy,
      isFalse,
    );
  });

  testWidgets('a link whose server does not answer says so under the host', (
    tester,
  ) async {
    await _pump(
      tester,
      unreachable: true,
      initial: (server: Uri.parse('https://chat.example'), code: 'CODE1'),
    );
    await _acceptAndContinue(tester);
    await _pumpUntil(
      tester,
      () => find.text('Could not reach that server.').evaluate().isNotEmpty,
    );

    expect(_banner(), findsNothing);
    expect(
      tester.getTopLeft(find.text('Could not reach that server.')).dy,
      lessThan(tester.getTopLeft(_field('Invite code')).dy),
    );
  });

  testWidgets('on a phone the full-screen page puts a refused code under the '
      'code field, not in a banner', (tester) async {
    await _pump(tester, fullScreen: true);
    await _continueWith(
      tester,
      server: 'https://chat.example',
      code: 'DEADCODE1',
    );
    await _pumpUntil(tester, () => _errorUnder(tester, 'Invite code') != null);

    expect(_errorUnder(tester, 'Invite code'), inviteUnusable);
    expect(
      find.descendant(
        of: _field('Invite code'),
        matching: find.text(inviteUnusable),
      ),
      findsOneWidget,
    );
    expect(_banner(), findsNothing);
  });

  testWidgets('editing the field clears its error', (tester) async {
    await _pump(tester);
    await _continueWith(tester, server: 'not a url', code: 'CODE1');
    expect(_errorUnder(tester, 'Server'), isNotNull);

    await tester.enterText(_field('Server'), 'chat.example');
    await tester.pump();

    expect(_errorUnder(tester, 'Server'), isNull);
  });
}
