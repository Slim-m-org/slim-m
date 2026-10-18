// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ReportHistoryRow` renders the four fields decision 0015's audit trail
/// exists to answer - actor, action, subject and timestamp - for both halves
/// of the merged `/reports/history` feed: an audit-log entry and a resolved
/// report.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/settings/screens/admin/report_history_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'mod-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String _profileJson(String id, String name) => jsonEncode({
  'id': id,
  'username': name.toLowerCase(),
  'display_name': name,
  'created_at': 0,
});

/// Mounts [item] alone, with [names] already resolved into
/// `batchProfilesControllerProvider` (a real `resolve()` against a fake
/// `/users`, the same shape `report_card_harness.dart` uses) so the row
/// renders names rather than "Loading...".
Future<void> _pumpRow(
  WidgetTester tester,
  api.ModerationHistoryItem item,
  Map<String, String> names,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.method == 'GET' && request.url.path == '/users') {
          final ids = request.url.queryParameters['ids']!.split(',');
          final found = [
            for (final id in ids)
              if (names[id] case final name?) _profileJson(id, name),
          ];
          return http.Response(
            '[${found.join(',')}]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    ],
  );
  addTearDown(container.dispose);

  await container
      .read(batchProfilesControllerProvider.notifier)
      .resolve(names.keys);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: ReportHistoryRow(item: item)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Whether some [Text] in the tree matches [actor] followed by a
/// date-shaped tail, without pinning the exact string `formatDateTime`
/// produces - that depends on the host's local time zone and 12/24-hour
/// preference, neither of which this test controls.
Finder _actorAndTimestamp(String actor) => find.byWidgetPredicate((widget) {
  if (widget is! Text || widget.data == null) return false;
  return RegExp(
    '^${RegExp.escape(actor)} · \\d{4}-\\d{2}-\\d{2}',
  ).hasMatch(widget.data!);
});

void main() {
  testWidgets('an audit-log entry shows actor, action, subject and timestamp', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      const api.AuditLogHistoryEntry(
        id: '1',
        actorId: 'actor-1',
        subjectId: 'subject-1',
        action: api.AuditLogAction.remove,
        createdAt: 0,
      ),
      {'actor-1': 'Mod Actor', 'subject-1': 'Target User'},
    );

    expect(
      find.text('Target User'),
      findsOneWidget,
      reason: 'subject headline',
    );
    expect(
      find.text('REMOVED'),
      findsOneWidget,
      reason: 'action badge (AppBadge renders its label uppercased)',
    );
    expect(
      _actorAndTimestamp('Mod Actor'),
      findsOneWidget,
      reason: 'actor and timestamp, on the same detail line',
    );
  });

  testWidgets(
    'a resolved report shows the resolving moderator, its resolution, the '
    'subject and a timestamp',
    (tester) async {
      await _pumpRow(
        tester,
        const api.ResolvedReportHistoryEntry(
          id: 'r1',
          subjectKind: api.ReportSubject.user,
          subjectId: 'subject-1',
          reason: 'spam',
          createdAt: 0,
          resolvedAt: 0,
          resolvedBy: 'resolver-1',
          resolution: api.ReportResolution.resolved,
        ),
        {'subject-1': 'Target User', 'resolver-1': 'Mod Resolver'},
      );

      expect(find.text('Target User'), findsOneWidget, reason: 'subject');
      expect(find.text('RESOLVED'), findsOneWidget, reason: 'action badge');
      expect(
        _actorAndTimestamp('Mod Resolver'),
        findsOneWidget,
        reason: 'the resolving moderator and a timestamp',
      );
    },
  );
}
