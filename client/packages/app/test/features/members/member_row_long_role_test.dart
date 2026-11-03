// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A long role name never renders as a clipped chip: the name keeps its space
/// and the role folds into a +1 chip that lists it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_app/src/features/members/widgets/member_row_badges.dart';
import 'package:slimm_design_system/design_system.dart';

const _bob = api.UserProfile(
  id: 'bob',
  username: 'bob',
  displayName: 'Bob',
  createdAt: 0,
  roleIds: ['r-long'],
  roles: ['moderatorModeratorsOfTheWholeCommunity'],
);

Finder _more() =>
    find.byWidgetPredicate((w) => w is MemberRowMoreChip).hitTestable();

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
      final chip = tester.getRect(_more());
      expect(
        find.byWidgetPredicate((w) => w is AppBadge).hitTestable(),
        findsNothing,
      );
      expect(name.width, greaterThan(0));
      expect(name.right, lessThanOrEqualTo(chip.left));
      expect(chip.right, lessThanOrEqualTo(row.right));
      final tip = tester.widget<Tooltip>(
        find.descendant(of: _more(), matching: find.byType(Tooltip)),
      );
      expect(tip.message, _bob.roles.first);
      expect(tester.takeException(), isNull);
    });
  }
}
