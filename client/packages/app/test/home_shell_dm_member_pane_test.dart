// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner's report: opening a DM at a width that docks the member pane
/// showed it anyway, with the deployment's whole roster in it -
/// `memberPaneVisibleProvider` defaults open, and nothing before this
/// checked the selected channel's own kind, so hiding only the header's
/// toggle (`channel_screen_dm_header_test.dart`) would have left the pane
/// showing by default regardless. `_MemberPaneSlot` is what withholds it
/// here; the compact layout's own drawer (button and edge-swipe both) is
/// covered here too, since it is a second, independent route to the same pane.
///
/// Split out from `home_shell_test.dart` to keep both under this repo's file budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_data/data.dart';

import 'home_shell_harness.dart';

void main() {
  testWidgets(
    'the member pane stays hidden for a DM at expanded width, even though '
    'the toggle defaults open',
    (tester) async {
      final s = setup(httpClient: quietClient(), signedIn: true);
      await MessageStore(s.db).upsertChannels([
        const api.Channel(id: 'c1', name: 'Alice', kind: 'dm', createdAt: 0),
      ]);

      await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');

      expect(
        find.byType(AppMemberPane),
        findsNothing,
        reason:
            "a DM's two participants are never the deployment roster the "
            'pane answers with',
      );

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'an ordinary text channel at the same width is unaffected - the pane '
    'still shows',
    (tester) async {
      final s = setup(httpClient: quietClient(), signedIn: true);
      await MessageStore(s.db).upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
      ]);

      await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');

      expect(find.byType(AppMemberPane), findsOneWidget);

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'the compact app bar offers no members action for a DM, and its end '
    'drawer is withheld entirely - not just the button that would open it',
    (tester) async {
      final s = setup(httpClient: quietClient(), signedIn: true);
      await MessageStore(s.db).upsertChannels([
        const api.Channel(id: 'c1', name: 'Alice', kind: 'dm', createdAt: 0),
      ]);

      await pumpAtWidth(tester, s.container, 500, location: '/channels/c1');

      expect(find.bySemanticsLabel('Show members'), findsNothing);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.endDrawer,
        isNull,
        reason:
            "a Scaffold's default edge-swipe gesture would still reach an "
            'endDrawer left configured, even with no button open it',
      );

      await teardown(tester, s.container, s.db);
    },
  );
}
