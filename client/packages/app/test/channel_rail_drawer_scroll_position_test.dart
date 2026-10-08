// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner's report: on a phone with a long channel list, swiping the
/// drawer open again lost the scroll position and started back at the top.
/// A `Drawer`'s subtree is disposed on close, so the rail's scroll view was
/// rebuilt at offset 0 every reopen; see `channel_rail_drawer.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/channel_rail.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

/// Enough channels, in one category, that the rail overflows at phone
/// height - the owner's own "a lot of channels" shape.
final _manyChannels = [
  for (var i = 0; i < 48; i++)
    api.Channel(
      id: 'many-$i',
      name: 'channel-$i',
      kind: 'text',
      createdAt: 0,
      categoryId: 'cat-text',
    ),
];

Future<({ProviderContainer container, SlimmDatabase db})> _pumpAtWidth(
  WidgetTester tester,
  double width, {
  String location = '/channels/c-general',
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer();
  final store = await fixture.container.read(storeProvider.future);
  await store.replaceCategories(fixtureCategories);
  await store.upsertChannels(_manyChannels);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter(location),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

Future<void> _dragFromLeftEdge(WidgetTester tester) async {
  await tester.dragFrom(const Offset(5, 300), const Offset(300, 0));
  await tester.pumpAndSettle();
}

// .first: the managed branch nests a second (never-scrollable) Scrollable inside the rail's outer one.
double _railScrollOffset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position
    .pixels;

void main() {
  testWidgets(
    'reopening the drawer keeps the scroll position instead of resetting '
    'to the top',
    (tester) async {
      final fixture = await _pumpAtWidth(
        tester,
        390,
        location: '/channels/many-0',
      );
      await _dragFromLeftEdge(tester);

      // Scroll well down the long list.
      await tester.drag(find.byType(ChannelRail), const Offset(0, -1200));
      await tester.pumpAndSettle();
      final scrolled = _railScrollOffset(tester);
      expect(scrolled, greaterThan(0), reason: 'the drag has to have moved it');

      // Close (scrim tap, past the drawer's own width) and reopen.
      await tester.tapAt(const Offset(370, 300));
      await tester.pumpAndSettle();
      expect(find.byType(ChannelRail), findsNothing);
      await _dragFromLeftEdge(tester);

      expect(
        _railScrollOffset(tester),
        closeTo(scrolled, 1),
        reason:
            'the drawer is a fresh subtree on reopen; only the owned offset carries across it',
      );

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );

  testWidgets(
    'opening the drawer on a channel far down the list scrolls it into view',
    (tester) async {
      // No prior scroll from this drawer to fall back on - the deep-link/notification case.
      final fixture = await _pumpAtWidth(
        tester,
        390,
        location: '/channels/many-47',
      );
      await _dragFromLeftEdge(tester);

      expect(
        _railScrollOffset(tester),
        greaterThan(0),
        reason: 'channel-47 is nowhere near the top of a 48-channel list',
      );
      final rowY = tester
          .getTopLeft(
            find.descendant(
              of: find.byType(ChannelRail),
              matching: find.text('channel-47'),
            ),
          )
          .dy;
      final viewport = tester.getRect(find.byType(ChannelRail));
      expect(
        rowY,
        inInclusiveRange(viewport.top, viewport.bottom),
        reason:
            'ensureVisible must land the selected row inside the viewport, not merely off zero',
      );

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );
}
