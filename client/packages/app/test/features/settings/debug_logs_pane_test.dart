// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin list of received debug logs: rows, empty and failed loads,
/// copy, and delete with its confirmation and its inline failure.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/screens/admin/debug_logs_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'admin-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _entry(int id, {String note = ''}) => {
  'id': id,
  'user_id': 'u$id',
  'username': 'user$id',
  'display_name': 'Member $id',
  'note': note,
  'app_version': '0.1.0+1',
  'platform': 'linux',
  'size_bytes': 2048,
  'created_at': DateTime.now().millisecondsSinceEpoch - id * 60000,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Future<List<String>> _pump(
  WidgetTester tester,
  http.Response Function(http.Request request) answer,
) async {
  final seen = <String>[];
  await pumpInApp(
    tester,
    const DebugLogsPane(),
    settle: false,
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        seen.add('${request.method} ${request.url.path}');
        return answer(request);
      }),
    ],
  );
  await pumpFrames(tester);
  return seen;
}

void main() {
  testWidgets('lists who sent each log, from what, and the note', (
    tester,
  ) async {
    await _pump(
      tester,
      (_) => _json([_entry(2, note: 'settings reset'), _entry(1)]),
    );
    expect(find.text('Member 2'), findsOneWidget);
    expect(find.text('settings reset'), findsOneWidget);
    expect(find.text('linux - 0.1.0+1'), findsNWidgets(2));
    expect(find.textContaining('- 2 KB'), findsNWidgets(2));
    expect(find.byTooltip('Download'), findsNWidgets(2));
  });

  testWidgets('an empty list says so', (tester) async {
    await _pump(tester, (_) => _json(<Object>[]));
    expect(find.text('No debug logs received'), findsOneWidget);
  });

  testWidgets('a failed load shows the persistent error with a retry', (
    tester,
  ) async {
    await _pump(tester, (_) => _json({'error': 'nope'}, 500));
    expect(find.text('Could not load the debug logs.'), findsOneWidget);
  });

  testWidgets('copy puts the full text on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final seen = await _pump(
      tester,
      (request) => request.url.path == '/debug-logs/1'
          ? _json({..._entry(1), 'log': 'the whole log'})
          : _json([_entry(1)]),
    );
    await tester.tap(find.byTooltip('Copy'));
    await pumpFrames(tester);
    expect(seen, contains('GET /debug-logs/1'));
    expect(copied, 'the whole log');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('delete asks first, then removes the row', (tester) async {
    final seen = await _pump(
      tester,
      (request) => request.method == 'DELETE'
          ? http.Response('', 204)
          : _json([_entry(1)]),
    );
    await tester.tap(find.byTooltip('Delete'));
    await pumpFrames(tester);
    expect(find.text('Delete debug log?'), findsOneWidget);
    expect(seen, isNot(contains('DELETE /debug-logs/1')));

    await tester.tap(find.text('Delete'));
    await pumpFrames(tester);
    expect(seen, contains('DELETE /debug-logs/1'));
    expect(find.text('Member 1'), findsNothing);
  });

  testWidgets('a failed delete keeps the row and says why, inline', (
    tester,
  ) async {
    await _pump(
      tester,
      (request) => request.method == 'DELETE'
          ? _json({'error': 'gone'}, 500)
          : _json([_entry(1)]),
    );
    await tester.tap(find.byTooltip('Delete'));
    await pumpFrames(tester);
    await tester.tap(find.text('Delete'));
    await pumpFrames(tester);
    expect(find.text('Member 1'), findsOneWidget);
    expect(find.textContaining('delete the debug log'), findsOneWidget);
  });
}
