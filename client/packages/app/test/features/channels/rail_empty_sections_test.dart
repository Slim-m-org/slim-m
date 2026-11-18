// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A rail section with nothing in it says so under its header, rather than
/// leaving a bare heading or a chevron with nothing to fold.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_drag_lift.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart'
    show presenceSeedProvider;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'channel_management_harness.dart';

void main() {
  testWidgets('no direct messages says so under its header', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [presenceSeedProvider.overrideWith((ref, _) async {})],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: DirectMessagesSection(
              channels: [],
              selectedId: null,
              listed: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Direct messages'), findsOneWidget);
    expect(find.text('No direct messages yet.'), findsOneWidget);
  });

  testWidgets('a manager sees an empty category as one with no channels yet', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        ChannelCategorySections(
          channels: [channel('c1', 'general', categoryId: 'cat-1')],
          categories: const [
            ChannelCategoryRow(id: 'cat-1', name: 'Text', position: 0),
            ChannelCategoryRow(id: 'cat-2', name: 'Staff', position: 1),
            ChannelCategoryRow(
              id: 'cat-3',
              name: 'Archive',
              position: 2,
              parentId: 'cat-2',
            ),
          ],
          selectedId: null,
          canManage: true,
          onReorder: (_) {},
        ),
        handler: (_) => http.Response('{}', 200),
      ),
    );

    expect(find.text('No channels yet.'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('No channels yet.')).dy,
      greaterThan(tester.getTopLeft(find.text('Archive')).dy),
    );
  });

  testWidgets(
    'picking up a channel on a phone keeps an empty category\'s line',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [
              channel('c1', 'general', categoryId: 'cat-1'),
              channel('c2', 'random', categoryId: 'cat-1'),
            ],
            categories: const [
              ChannelCategoryRow(id: 'cat-2', name: 'Staff', position: 0),
              ChannelCategoryRow(id: 'cat-1', name: 'Text', position: 1),
            ],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );
      double staffToText() =>
          tester.getTopLeft(find.text('Text')).dy -
          tester.getTopLeft(find.text('Staff')).dy;
      final before = staffToText();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('general')),
      );
      await tester.pump(kLongPressTimeout + kPressTimeout);
      await gesture.moveBy(const Offset(0, kTouchSlop + 4));
      await tester.pump();
      await tester.pump();

      expect(
        find.byWidgetPredicate((w) => w is RailDragLift),
        findsOneWidget,
        reason: 'the row is lifted',
      );
      expect(staffToText(), before, reason: 'the empty hint keeps its line');
      await gesture.up();
    },
  );
}
