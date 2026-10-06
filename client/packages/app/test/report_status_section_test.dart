// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Reports you filed": each remembered report is fetched and worded as
/// resolved or still open, and one that is gone says so. The by-id check has
/// its own wording, and the relative time has fixed bucket boundaries.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/filed_reports.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/report_status_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _status(String id, String status) => {
  'id': id,
  'subject_kind': 'message',
  'subject_id': 'm1',
  'channel_id': 'c1',
  'created_at': DateTime.now().millisecondsSinceEpoch,
  'status': status,
};

http.Response _handle(http.Request request) {
  final id = request.url.pathSegments.last;
  const json = {'content-type': 'application/json'};
  return switch (id) {
    'r-open' => http.Response(
      jsonEncode(_status(id, 'open')),
      200,
      headers: json,
    ),
    'r-done' => http.Response(
      jsonEncode(_status(id, 'resolved')),
      200,
      headers: json,
    ),
    _ => http.Response(jsonEncode({'error': 'not found'}), 404, headers: json),
  };
}

Future<void> _pump(WidgetTester tester, List<String> filed) async {
  SharedPreferences.setMockInitialValues({filedReportsKey('self'): filed});
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async => _handle(request)),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: ReportStatusSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('each filed report says resolved or still open, or gone', (
    tester,
  ) async {
    await _pump(tester, ['r-done', 'r-open', 'r-gone']);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.text('Resolved. Filed just now.'), findsOneWidget);
    expect(find.text('Still open. Filed just now.'), findsOneWidget);
    expect(find.text('No longer available.'), findsOneWidget);
  });

  testWidgets('with nothing filed it says so', (tester) async {
    await _pump(tester, const []);

    expect(find.text('Nothing filed from this device yet.'), findsOneWidget);
  });

  testWidgets('checking an id by hand words the result, and a miss', (
    tester,
  ) async {
    await _pump(tester, const []);

    await tester.enterText(find.byType(TextField), 'r-done');
    await tester.tap(find.widgetWithText(AppButton, 'Check'));
    await tester.pumpAndSettle();
    expect(find.text('Resolved. Filed just now.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.widgetWithText(AppButton, 'Check'));
    await tester.pumpAndSettle();
    expect(find.text('No report found with that ID.'), findsOneWidget);
    expect(find.text('Resolved. Filed just now.'), findsNothing);
  });

  test('filedAgo buckets sit on their boundaries', () {
    final now = DateTime(2026, 1, 20, 12);
    String ago(Duration d) =>
        filedAgo(now.subtract(d).millisecondsSinceEpoch, now: now);

    expect(ago(const Duration(seconds: 59)), 'just now');
    expect(ago(const Duration(seconds: 60)), '1m ago');
    expect(ago(const Duration(minutes: 59)), '59m ago');
    expect(ago(const Duration(minutes: 60)), '1h ago');
    expect(ago(const Duration(hours: 23)), '23h ago');
    expect(ago(const Duration(hours: 24)), '1d ago');
    expect(ago(const Duration(days: 6)), '6d ago');
    expect(ago(const Duration(days: 7)), '1w ago');
    expect(ago(const Duration(days: 15)), '2w ago');
  });
}
