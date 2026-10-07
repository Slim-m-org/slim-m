// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A saved capacity setting stays on screen when the refetch that follows the
/// save fails: a refetch that errored still holds the old value, and showing
/// it would snap the control back to what was just replaced.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/performance_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// Serves the three settings at their defaults, takes every PATCH, and fails
/// every GET of [brokenPath] once a PATCH has gone through.
Widget _app(String brokenPath) {
  var saved = false;
  final client = MockClient((request) async {
    if (request.method == 'PATCH') {
      saved = true;
      return _json({
        'retention_days': 30,
        'object_cap': 50000,
        'max_height': 720,
      });
    }
    if (saved && request.url.path == brokenPath) {
      return http.Response('down', 500);
    }
    return switch (request.url.path) {
      '/space/retention' => _json({'retention_days': 0}),
      '/space/canvas-cap' => _json({'object_cap': 20000}),
      '/space/screen-share' => _json({'max_height': 2160}),
      _ => _json({'enabled': false}),
    };
  });
  final container = ProviderContainer(
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
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: const Scaffold(body: PerformanceScreen()),
    ),
  );
}

Future<void> _tapOption(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the canvas cap keeps the saved value when the refetch fails', (
    tester,
  ) async {
    await tester.pumpWidget(_app('/space/canvas-cap'));
    await tester.pumpAndSettle();
    await _tapOption(tester, '50,000');
    expect(find.textContaining('Past what was measured'), findsOneWidget);
  });

  testWidgets('the screen share cap keeps the saved value when the refetch '
      'fails', (tester) async {
    await tester.pumpWidget(_app('/space/screen-share'));
    await tester.pumpAndSettle();
    await _tapOption(tester, '720p');
    expect(find.textContaining('Shares are capped at'), findsOneWidget);
  });

  testWidgets('message retention keeps the saved value when the refetch '
      'fails', (tester) async {
    await tester.pumpWidget(_app('/space/retention'));
    await tester.pumpAndSettle();
    await _tapOption(tester, '30 days');
    expect(find.textContaining('Prunes anything older'), findsOneWidget);
  });
}
