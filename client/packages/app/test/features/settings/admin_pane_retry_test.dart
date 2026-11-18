// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The paged admin panes show a spinner while a retry runs, and still widen
/// their wait from one failure to the next; a lost permission is never retried.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/settings/providers/admin_audit_names.dart';
import 'package:slimm_app/src/features/settings/providers/admin_audit_wording.dart';
import 'package:slimm_app/src/features/settings/screens/admin/audit_log_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/debug_logs_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/report_history_pane.dart';
import 'package:slimm_app/src/features/settings/screens/admin/reports_screen.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'admin-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _panes = <(String, Widget, String)>[
  ('audit log', AuditLogPane(), '/space/audit-log'),
  ('debug logs', DebugLogsPane(), '/debug-logs'),
  ('open reports', ReportsPane(), '/reports'),
  ('moderation history', ReportHistoryPane(), '/reports/history'),
];

/// Mounts [pane] the way the app does, answering [path] with [status] every time; returns the requests to it.
Future<List<Uri>> _pump(
  WidgetTester tester,
  Widget pane,
  String path,
  int status,
) async {
  final seen = <Uri>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      adminAuditNamesProvider.overrideWith((ref) => const AuditNames()),
      mockApiOverride((request) async {
        if (request.url.path != path) {
          return http.Response('[]', 200, headers: _jsonType);
        }
        seen.add(request.url);
        await Future<void>.delayed(_roundTrip);
        return http.Response(
          jsonEncode({'error': 'nope'}),
          status,
          headers: _jsonType,
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        builder: appChromeBuilder,
        home: Scaffold(body: pane),
      ),
    ),
  );
  await _answered(tester);
  return seen;
}

const _jsonType = {'content-type': 'application/json'};

/// Long enough that a retry's spinner draws before its answer lands, as on a real network.
const _roundTrip = Duration(milliseconds: 300);

Future<void> _answered(WidgetTester tester) async {
  await tester.pump(_roundTrip);
  await tester.pump();
}

void main() {
  for (final (name, pane, path) in _panes) {
    testWidgets('the $name waits longer after each failed retry', (
      tester,
    ) async {
      final seen = await _pump(tester, pane, path, 503);
      expect(seen, hasLength(1));

      await tester.pump(appLoadRetryDelays[0]);
      expect(
        find.textContaining('Could not load'),
        findsNothing,
        reason: 'the retry shows its spinner',
      );
      await _answered(tester);
      expect(seen, hasLength(2));

      await tester.pump(appLoadRetryDelays[0]);
      await _answered(tester);
      expect(seen, hasLength(2), reason: 'the second wait is the longer one');

      await tester.pump(appLoadRetryDelays[1] - appLoadRetryDelays[0]);
      await _answered(tester);
      expect(seen, hasLength(3));
    });

    testWidgets('the $name never retries a lost permission', (tester) async {
      final seen = await _pump(tester, pane, path, 403);
      expect(find.textContaining('Could not load'), findsOneWidget);

      await tester.pump(appLoadRetryDelays.last * 3);
      await _answered(tester);
      expect(seen, hasLength(1));
      expect(find.text('Retry'), findsNothing);
    });
  }
}
