// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// At 600-835 px the member pane has no room to dock, and the header used to
/// offer nothing in its place, so the roster, profiles and moderation were
/// unreachable. The same end drawer compact uses now answers there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_data/data.dart';

import '../../home_shell_harness.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _withChannel(
  String kind,
) async {
  final s = setup(httpClient: quietClient(), signedIn: true);
  await MessageStore(s.db).upsertChannels([
    api.Channel(id: 'c1', name: 'general', kind: kind, createdAt: 0),
  ]);
  return s;
}

void main() {
  for (final width in [600.0, 700.0, 800.0]) {
    testWidgets('at $width px the header has a members control that opens the '
        'roster', (tester) async {
      final s = await _withChannel('text');
      await pumpAtWidth(tester, s.container, width, location: '/channels/c1');

      final control = find.bySemanticsLabel('Show members');
      expect(control, findsOneWidget);
      final rect = tester.getRect(control);
      expect(rect.width, greaterThan(0));
      expect(rect.right, lessThanOrEqualTo(width));
      expect(find.byType(AppMemberPane, skipOffstage: false), findsNothing);

      await tester.tap(control);
      await tester.pumpAndSettle();

      final pane = find.byType(AppMemberPane);
      expect(pane, findsOneWidget);
      expect(tester.getRect(pane).right, width);
      expect(tester.getSize(pane).width, AppMemberPane.width);

      await teardown(tester, s.container, s.db);
    });
  }

  testWidgets('a DM at medium width offers no members control or drawer', (
    tester,
  ) async {
    final s = await _withChannel('dm');
    await pumpAtWidth(tester, s.container, 700, location: '/channels/c1');

    expect(find.bySemanticsLabel('Show members'), findsNothing);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.endDrawer, isNull);

    await teardown(tester, s.container, s.db);
  });

  testWidgets('where the pane docks there is one members control, not two', (
    tester,
  ) async {
    final s = await _withChannel('text');
    await pumpAtWidth(tester, s.container, 955, location: '/channels/c1');

    expect(find.bySemanticsLabel('Show members'), findsNothing);
    expect(find.bySemanticsLabel('Toggle member list'), findsOneWidget);

    await teardown(tester, s.container, s.db);
  });
}
