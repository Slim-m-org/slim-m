// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A long role name truncates its own chip; the member's name keeps its space
/// and the chip stays inside the pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_design_system/design_system.dart';

const _bob = api.UserProfile(
  id: 'bob',
  username: 'bob',
  displayName: 'Bob',
  createdAt: 0,
  roleIds: ['r-long'],
  roles: ['moderatorModeratorsOfTheWholeCommunity'],
);

void main() {
  for (final width in [236.0, 390.0]) {
    testWidgets('long role chip leaves the name drawn at ${width}px', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            liveEventsProvider.overrideWithValue(
              const Stream<api.ServerEvent>.empty(),
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: const MemberRow(profile: _bob, isSelf: false),
                ),
              ),
            ),
          ),
        ),
      );
      final row = tester.getRect(find.byType(MemberRow));
      final name = tester.getRect(find.text('Bob'));
      final chip = tester.getRect(find.byType(AppBadge));
      expect(name.width, greaterThan(0));
      expect(name.right, lessThanOrEqualTo(chip.left));
      expect(chip.right, lessThanOrEqualTo(row.right));
      expect(tester.takeException(), isNull);
    });
  }
}
