// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A big community's people list builds only the rows in view.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/group_dm_people_list.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('2000 members build only the visible rows', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          membersProvider.overrideWith(
            (ref) async => [
              for (var i = 0; i < 2000; i++)
                api.UserProfile(
                  id: 'u$i',
                  username: 'user$i',
                  displayName: 'Person $i',
                  createdAt: 0,
                ),
            ],
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: GroupDmPeopleList(
              exclude: const {},
              selected: const {},
              onTap: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final built = find.byWidgetPredicate(
      (w) => w is AppListRow && w.key.toString().contains('group-dm-person'),
    );
    expect(built, findsWidgets);
    expect(built.evaluate().length, lessThan(30));
  });
}
