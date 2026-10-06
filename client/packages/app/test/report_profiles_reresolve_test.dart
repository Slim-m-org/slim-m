// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reports queue and moderation history ask for their names again when the
/// profile cache is cleared (a reconnect) or an id is evicted (a rename).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/user_profiles.dart';

import 'report_card_harness.dart';

void main() {
  testWidgets('a report card gets its names back after profiles are cleared', (
    tester,
  ) async {
    final h = await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'r1',
          subjectKind: 'user',
          subjectId: 'subject-1',
          reporterId: 'reporter-1',
        ),
      ],
      profiles: {'subject-1': 'Bob', 'reporter-1': 'Carol'},
    );
    expect(find.text('Carol'), findsOneWidget);

    // What sync_controller does on every (re)connect.
    h.container.read(batchProfilesControllerProvider.notifier).clear();
    await tester.pumpAndSettle();

    expect(
      find.text('Carol'),
      findsOneWidget,
      reason: 'reporter name should be re-requested, not stuck on Loading...',
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Loading...'), findsNothing);
  });

  testWidgets('history rows get their names back after profiles are cleared', (
    tester,
  ) async {
    final h = await pumpReports(
      tester,
      reports: [],
      history: [
        '{"kind":"audit_log","id":"a1","actor_id":"mod-1",'
            '"subject_id":"user-1","action":"remove","reason":null,'
            '"until":null,"created_at":0}',
      ],
      profiles: {'mod-1': 'Mod One', 'user-1': 'Some User'},
    );
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('Some User'), findsOneWidget);

    h.container.read(batchProfilesControllerProvider.notifier).clear();
    await tester.pumpAndSettle();

    expect(
      find.text('Some User'),
      findsOneWidget,
      reason: 'history subject name should be re-requested',
    );
    expect(find.text('Loading...'), findsNothing);
  });
}
