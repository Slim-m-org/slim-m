// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A row under its own role's heading leaves the role badge off, since it
/// would only repeat the heading; anywhere else the badge stays.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_design_system/design_system.dart';

const _ada = api.UserProfile(
  id: 'ada',
  username: 'ada',
  displayName: 'Ada',
  createdAt: 0,
  roleIds: ['r-admin', 'r-mod'],
  roles: ['Admin', 'Mod'],
);

Future<void> _pump(WidgetTester tester, {String? sectionRoleId}) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveEventsProvider.overrideWithValue(
            const Stream<api.ServerEvent>.empty(),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: MemberRow(
              profile: _ada,
              isSelf: false,
              sectionRoleId: sectionRoleId,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('no badge under the role section the badge names', (
    tester,
  ) async {
    await _pump(tester, sectionRoleId: 'r-admin');
    expect(find.text('Ada'), findsOneWidget);
    expect(find.byType(AppBadge), findsNothing);
  });

  testWidgets('the badge stays in Online, Offline and Bots', (tester) async {
    await _pump(tester);
    expect(find.byType(AppBadge), findsOneWidget);
    expect(tester.widget<AppBadge>(find.byType(AppBadge)).label, 'Admin');
  });
}
