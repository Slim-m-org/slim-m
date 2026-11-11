// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The send sheet: says what goes, sends the scrubbed log with the note, and
/// shows sent or an inline error that stays.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/features/settings/providers/debug_log_send.dart';
import 'package:slimm_app/src/features/settings/widgets/debug_log_send_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/mock_app_version.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<List<http.Request>> _open(
  WidgetTester tester,
  http.Response Function(http.Request) answer,
) async {
  final sent = <http.Request>[];
  final container = await pumpInApp(
    tester,
    const DebugLogSendSheet(),
    settle: false,
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        sent.add(request);
        return answer(request);
      }),
    ],
  );
  container.read(debugLogProvider.notifier)
    ..record('sync', 'refresh failed', detail: 'Bearer topsecret')
    ..record('ui', 'overflowed');
  await pumpFrames(tester);
  return sent;
}

http.Response _created(http.Request _) => http.Response(
  jsonEncode({'id': 1, 'created_at': 2}),
  201,
  headers: const {'content-type': 'application/json'},
);

void main() {
  setUpAll(mockAppVersion);

  testWidgets('names what is sent before sending anything', (tester) async {
    final sent = await _open(tester, _created);
    expect(find.textContaining('debug log, your app version'), findsOneWidget);
    expect(
      find.text('2 log entries, version 0.1.0+1, ${debugLogPlatform()}'),
      findsOneWidget,
    );
    expect(sent, isEmpty);
  });

  testWidgets('sends the scrubbed log and the note, then says sent', (
    tester,
  ) async {
    final sent = await _open(tester, _created);
    await tester.enterText(
      find.byKey(const ValueKey('debug-log-note-field')),
      '  my settings reset  ',
    );
    await tester.tap(find.text('Send'));
    await pumpFrames(tester);

    final body = jsonDecode(sent.single.body) as Map<String, dynamic>;
    expect(sent.single.url.path, '/debug-logs');
    expect(body['note'], 'my settings reset');
    expect(body['app_version'], '0.1.0+1');
    expect(body['log'], contains('refresh failed'));
    expect(body['log'], isNot(contains('topsecret')));
    expect(find.text('Sent. The admins can now read it.'), findsOneWidget);
  });

  testWidgets('a refusal shows inline, stays, and can be retried', (
    tester,
  ) async {
    var attempts = 0;
    final sent = await _open(tester, (request) {
      attempts++;
      return attempts == 1
          ? http.Response(
              jsonEncode({'error': 'the debug log is over 1 MiB'}),
              400,
              headers: const {'content-type': 'application/json'},
            )
          : _created(request);
    });
    await tester.tap(find.text('Send'));
    await pumpFrames(tester);

    expect(find.textContaining('send the debug log'), findsOneWidget);
    expect(find.text('Sent. The admins can now read it.'), findsNothing);

    await tester.tap(find.text('Send'));
    await pumpFrames(tester);
    expect(sent, hasLength(2));
    expect(find.text('Sent. The admins can now read it.'), findsOneWidget);
  });
}
