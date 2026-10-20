// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The locked-out half of account recovery: `screens/reset_password_sheet.dart`
/// spending an admin-issued code against `POST /auth/reset`.
///
/// The cases worth holding are the ones that cost something if they regress:
/// a code must not be spent on a password the server would refuse anyway, a
/// refusal must not say *which* kind of refusal it was, and the sheet must
/// report success back to its caller rather than pretending to sign in.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/reset_password_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

final _server = Uri.parse('https://chat.example');

/// Opens the sheet and hands back both the recorded reset calls and a getter
/// for what [showResetPasswordSheet] eventually resolved to.
Future<({List<Map<String, dynamic>> sent, bool? Function() result})> _open(
  WidgetTester tester, {
  required http.Client client,
}) async {
  final sent = <Map<String, dynamic>>[];
  bool? result;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => _server),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showResetPasswordSheet(context, _server);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (sent: sent, result: () => result);
}

/// Records every `/auth/reset` body and answers it with [status].
http.Client _resetClient(
  List<Map<String, dynamic>> sent, {
  int status = 204,
  String message = 'that reset code cannot be used',
}) => MockClient((request) async {
  if (request.url.path == '/auth/reset') {
    sent.add(jsonDecode(request.body) as Map<String, dynamic>);
    if (status == 204) return http.Response('', 204);
    return http.Response(
      jsonEncode({'error': message}),
      status,
      headers: const {'content-type': 'application/json'},
    );
  }
  return http.Response('{}', 200);
});

Future<void> _fill(
  WidgetTester tester, {
  required String code,
  required String password,
}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), code);
  await tester.enterText(fields.at(1), password);
  await tester.pump();
}

void main() {
  testWidgets('a password under the server minimum never spends the code', (
    tester,
  ) async {
    final sent = <Map<String, dynamic>>[];
    await _open(tester, client: _resetClient(sent));

    await _fill(tester, code: 'a-real-looking-code', password: 'short');
    await tester.tap(find.text('Set new password'));
    await tester.pumpAndSettle();

    expect(
      sent,
      isEmpty,
      reason:
          'a code is one-time, so a password the server would refuse anyway '
          'must be caught before the request burns it',
    );
    expect(find.textContaining('at least $kPasswordMinChars'), findsWidgets);
  });

  testWidgets('an empty code is refused before any request', (tester) async {
    final sent = <Map<String, dynamic>>[];
    await _open(tester, client: _resetClient(sent));

    await _fill(tester, code: '   ', password: 'a-long-enough-password');
    await tester.tap(find.text('Set new password'));
    await tester.pumpAndSettle();

    expect(sent, isEmpty);
    expect(find.textContaining('Enter the code'), findsOneWidget);
  });

  testWidgets('a good code sends it trimmed and reports success', (
    tester,
  ) async {
    final sent = <Map<String, dynamic>>[];
    final opened = await _open(tester, client: _resetClient(sent));

    await _fill(tester, code: '  code-abc  ', password: 'a-long-enough-pass');
    await tester.tap(find.text('Set new password'));
    await tester.pumpAndSettle();

    expect(sent, hasLength(1));
    expect(
      sent.single['code'],
      'code-abc',
      reason: 'pasted codes carry whitespace; the server sees the code alone',
    );
    expect(sent.single['new_password'], 'a-long-enough-pass');
    expect(
      opened.result(),
      isTrue,
      reason:
          'the caller says "sign in with your new password"; it can only do '
          'that if this reports the password was actually set',
    );
  });

  testWidgets('a refused code says so without saying which kind of refusal', (
    tester,
  ) async {
    final sent = <Map<String, dynamic>>[];
    await _open(tester, client: _resetClient(sent, status: 400));

    await _fill(tester, code: 'spent-code', password: 'a-long-enough-pass');
    await tester.tap(find.text('Set new password'));
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot be used'), findsOneWidget);
    for (final leak in const ['expired', 'already', 'unknown', 'not found']) {
      expect(
        find.textContaining(leak, skipOffstage: false),
        findsNothing,
        reason:
            'the server answers unknown, expired and spent identically so '
            'live codes cannot be mined; naming $leak here would undo that',
      );
    }
  });

  testWidgets('an unreachable server does not read as a bad code', (
    tester,
  ) async {
    await _open(
      tester,
      client: MockClient((_) async => throw const SocketishFailure()),
    );

    await _fill(tester, code: 'code-abc', password: 'a-long-enough-pass');
    await tester.tap(find.text('Set new password'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not reach'), findsOneWidget);
    expect(find.textContaining('cannot be used'), findsNothing);
  });

  testWidgets('recovery refuses an address it would not send a password to', (
    tester,
  ) async {
    final results = <bool?>[];
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        serverUrlProvider.overrideWith((ref) => _server),
        probeApiProvider.overrideWithValue(
          (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: _resetClient([])),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    results
                      ..add(await startAccountRecovery(context, ref, null))
                      ..add(
                        await startAccountRecovery(
                          context,
                          ref,
                          Uri.parse('http://chat.example'),
                        ),
                      );
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(
      results,
      [null, null],
      reason:
          'a reset carries a one-time code and a new password, so it must '
          'clear the same address bar sign-in does - an unparseable address '
          'and cleartext to the internet are both refused before the sheet '
          'ever opens',
    );
  });
}

/// A transport-layer throw, which [SlimmApi] wraps as a `TransportException`.
class SocketishFailure implements Exception {
  const SocketishFailure();
}
