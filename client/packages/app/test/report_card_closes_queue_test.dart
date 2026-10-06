// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Resolving or dismissing a report takes it out of the open queue.
///
/// The confirmation says it "removes it from the queue" and the request went
/// through, but nothing reloaded the list, so the card stayed and a second
/// press was answered with an error. The quick actions already refresh; the
/// two buttons now do too.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/reports_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'report_card_harness.dart';

/// A server holding one open report, which a PATCH closes unless [refuse].
class _Server {
  _Server({this.refuse = false});

  final bool refuse;
  bool open = true;
  int listings = 0;
  final patches = <String>[];

  Future<http.Response> handle(http.Request request) async {
    const json = {'content-type': 'application/json'};
    final path = request.url.path;
    if (request.method == 'GET' && path == '/reports') {
      listings++;
      final body = open
          ? '[${reportJson(id: 'r1', subjectKind: 'user', subjectId: 'u1', reporterId: 'u2')}]'
          : '[]';
      return http.Response(body, 200, headers: json);
    }
    if (path == '/reports/history' || path == '/users') {
      return http.Response('[]', 200, headers: json);
    }
    if (request.method == 'PATCH') {
      patches.add(request.body);
      if (refuse) return http.Response('{"error":"no"}', 500, headers: json);
      open = false;
      return http.Response('', 204);
    }
    return http.Response('{}', 200, headers: json);
  }
}

Future<_Server> _open(WidgetTester tester, {bool refuse = false}) async {
  final server = _Server(refuse: refuse);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(server.handle),
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
        home: const ReportsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return server;
}

Future<void> _press(WidgetTester tester, String verb) async {
  await tester.tap(find.widgetWithText(AppButton, verb));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(Dialog),
      matching: find.widgetWithText(AppButton, verb),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('resolving removes the report from the open queue', (
    tester,
  ) async {
    final server = await _open(tester);

    await _press(tester, 'Resolve');

    expect(server.patches, hasLength(1));
    expect(server.listings, 2, reason: 'the queue is reloaded after it');
    expect(find.text('Reported user'), findsNothing);
  });

  testWidgets('dismissing removes it too', (tester) async {
    final server = await _open(tester);

    await _press(tester, 'Dismiss');

    expect(server.patches, hasLength(1));
    expect(find.text('Reported user'), findsNothing);
  });

  testWidgets('a refused close keeps the card and says so', (tester) async {
    await _open(tester, refuse: true);

    await _press(tester, 'Resolve');

    expect(find.text('Reported user'), findsOneWidget);
    expect(find.textContaining('Could not close the report'), findsOneWidget);
  });

  testWidgets('cancelling the confirmation closes nothing', (tester) async {
    final server = await _open(tester);

    await tester.tap(find.widgetWithText(AppButton, 'Resolve'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(server.patches, isEmpty);
    expect(find.text('Reported user'), findsOneWidget);
  });
}
