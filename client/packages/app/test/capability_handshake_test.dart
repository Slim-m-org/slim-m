// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The capability handshake on the sign-in screen.
///
/// slim-m's safety model is manual reporting plus blocking and nothing else,
/// so a server offering neither leaves a member with no recourse. This checks
/// that the screen says so before anyone commits, that it never says it about
/// a server that has not been asked or is too old to answer, and that it never
/// blocks the connection either way.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

/// Everything `/version` carries that is not this test's subject.
Map<String, Object?> _version(Object? capabilities) => {
  'name': 'slim-m',
  'version': '0.17.0',
  'protocol': 1,
  'push_enabled': true,
  if (capabilities != null) 'capabilities': capabilities,
};

/// Pumps the sign-in screen against a server answering [body] on `/version`.
Future<void> pumpAgainst(
  WidgetTester tester,
  Map<String, Object?>? body,
) async {
  final httpClient = MockClient((request) async {
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
    ],
  );
  addTearDown(container.dispose);

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
}

final _missingNotice = find.textContaining('offers no way to');
final _unknownNotice = find.textContaining('too old to say whether it offers');

void main() {
  testWidgets('a server advertising both report and block says nothing', (
    tester,
  ) async {
    await pumpAgainst(tester, _version(['report', 'block']));
    expect(_missingNotice, findsNothing);
    expect(_unknownNotice, findsNothing);
  });

  testWidgets('a server advertising neither names both, and what it costs', (
    tester,
  ) async {
    await pumpAgainst(tester, _version(<String>[]));
    expect(_missingNotice, findsOneWidget);
    final text = tester.widget<Text>(_missingNotice).data!;
    expect(text, contains('report a message'));
    expect(text, contains('block anyone'));
    expect(
      text,
      contains('but you can still join'),
      reason: 'the notice informs; it never blocks',
    );
  });

  testWidgets('a server advertising only reporting names blocking alone', (
    tester,
  ) async {
    await pumpAgainst(tester, _version(['report']));
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
    expect(_missingNotice, findsNothing);
    expect(
      _unknownNotice,
      findsNothing,
      reason:
          'nothing has been heard back at all, which is not the same as a '
          'server that answered without a capability list',
    );
  });

  testWidgets('the warning does not block the connection', (tester) async {
    await pumpAgainst(tester, _version(<String>[]));
    expect(_missingNotice, findsOneWidget);
    final button = tester.widget<AppButton>(
      find.widgetWithText(AppButton, 'Sign in'),
    );
    expect(
      button.onPressed,
      isNotNull,
      reason: 'an operator may knowingly self-host without report and block',
    );
  });

  testWidgets('a capability list that is not a list reads as unknown', (
    tester,
  ) async {
    await pumpAgainst(tester, _version('report,block'));
    expect(_missingNotice, findsNothing);
    expect(_unknownNotice, findsOneWidget);
  });
}
