// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space voice uplink test: the last result and advice, a run, and a refusal while a call is live.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/uplink_test_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _result(int id, double mbit) => {
  'id': id,
  'measured_at': DateTime(2026, 11, 3, 12).millisecondsSinceEpoch,
  'mbit_per_s': mbit,
  'bytes': 41943040,
  'duration_ms': 3000,
};

Widget _app(MockClient client) => ProviderScope(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    apiProvider.overrideWith((ref) {
      final built = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: client,
      );
      ref.onDispose(built.close);
      return built;
    }),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: const Scaffold(
      body: SingleChildScrollView(child: UplinkTestSection()),
    ),
  ),
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('shows the last result with advice and runs a new test', (
    tester,
  ) async {
    var posts = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        posts++;
        return _json(_result(2, 50));
      }
      return _json({
        'results': [_result(posts + 1, posts == 0 ? 99 : 50)],
      });
    });
    await tester.pumpWidget(_app(client));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Measured 2026-11-03'), findsOneWidget);
    expect(find.textContaining('99 Mbit/s'), findsOneWidget);
    expect(find.text('Suggested ceiling: 2160p.'), findsOneWidget);
    expect(find.text('1080p60: 8 Mbit/s each, 8 at once'), findsOneWidget);

    await tester.tap(find.byKey(const Key('uplink-test-run')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(posts, 1);
    expect(find.textContaining('50 Mbit/s'), findsOneWidget);
  });

  testWidgets('a refusal while a call is live is shown inline', (tester) async {
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        return _json({'error': 'a call is live'}, 409);
      }
      return _json({'results': <Object>[]});
    });
    await tester.pumpWidget(_app(client));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('uplink-test-run')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('A call is live'), findsWidgets);
    expect(find.byType(SnackBar), findsNothing);
  });
}
