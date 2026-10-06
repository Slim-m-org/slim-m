// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The History pane with audit rows beyond the five moderation acts: the
/// server writes bot, webhook, account and nickname events into the same
/// feed, and a row the client has no label for must neither blank the tab
/// nor leave it spinning.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/report_history_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'mod-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _entry(String id, int createdAt, String action) => {
  'kind': 'audit_log',
  'id': id,
  'actor_id': null,
  'subject_id': 'subject-$id',
  'action': action,
  'reason': null,
  'until': null,
  'created_at': createdAt,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _pumpPane(
  WidgetTester tester,
  List<Object> Function() page,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/reports/history') return _json(page());
            return _json(<Object>[]);
          }),
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
        home: const Scaffold(body: ReportHistoryPane()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a nickname row and an unknown action each show a badge', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      () => [
        _entry('a2', 3, 'a_future_action'),
        _entry('a1', 2, 'nickname_set'),
        _entry('a0', 1, 'remove'),
      ],
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('OTHER ACTION'), findsOneWidget);
    expect(find.text('NICKNAME SET'), findsOneWidget);
    expect(find.text('REMOVED'), findsOneWidget);
  });

  testWidgets('a decode failure shows the error state and Retry recovers', (
    tester,
  ) async {
    var broken = true;
    await _pumpPane(
      tester,
      () => broken
          ? [
              {'kind': 'audit_log'},
            ]
          : [_entry('a0', 1, 'bot_create')],
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(AppErrorState), findsWidgets);
    expect(find.text('Could not load the moderation history.'), findsWidgets);

    broken = false;
    await tester.tap(find.text('Retry').first);
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsNothing);
    expect(find.text('BOT CREATED'), findsOneWidget);
  });
}
