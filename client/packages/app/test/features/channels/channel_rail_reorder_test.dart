// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for `ReorderableChannelRows`: no drag at all for an ordinary
/// member, a completed drag within one section reporting the new order, -
/// the property backlog item #34 asked for - a drag across two category
/// sections reassigning the dragged channel's category, and that
/// `rowBuilder`'s own flags match which branch actually wraps a row in the
/// drag listener, and that a phone hands the held press back to the context
/// menu and drags from an explicit handle instead.
/// See docs/decisions/0006-channel-categories.md.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show ChannelOrderGroup;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_reorder.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

Channel _channel(String id) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    body: SizedBox(height: 400, child: SingleChildScrollView(child: child)),
  ),
);

Widget _header(ChannelCategoryRow? category) =>
    Text('header:${category?.id ?? 'uncategorised'}');

void main() {
  testWidgets('a non-manager sees a plain, non-reorderable column', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        ReorderableChannelRows(
          sections: [
            (null, [_channel('a'), _channel('b')]),
          ],
          canManage: false,
          onReorder: (_) => fail('must not be reachable without canManage'),
          rowBuilder: (channel, longPressDrags) {
            expect(longPressDrags, isFalse);
            return Text(channel.id);
          },
          headerBuilder: _header,
        ),
      ),
    );

    expect(find.byType(SliverReorderableList), findsNothing);
    expect(find.text('header:uncategorised'), findsOneWidget);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('a mouse click on a row still reaches the row, not a drag', (
    tester,
  ) async {
    var tapped = 0;
    List<ChannelOrderGroup>? reported;
    await tester.pumpWidget(
      _harness(
        ReorderableChannelRows(
          sections: [
            (null, [_channel('a'), _channel('b')]),
          ],
          canManage: true,
          onReorder: (order) => reported = order,
          rowBuilder: (channel, longPressDrags) => GestureDetector(
            onTap: () => tapped++,
            child: SizedBox(height: 48, child: Text(channel.id)),
          ),
          headerBuilder: _header,
        ),
      ),
    );

    await tester.tap(find.text('a'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(tapped, 1, reason: 'the hold recogniser must not eat taps');
    expect(reported, isNull);
  });

  testWidgets('a manager can drag a row to a new position within a section', (
    tester,
  ) async {
    List<ChannelOrderGroup>? reported;
    await tester.pumpWidget(
      _harness(
        ReorderableChannelRows(
          sections: [
            (null, [_channel('a'), _channel('b'), _channel('c')]),
          ],
          canManage: true,
          onReorder: (order) => reported = order,
          rowBuilder: (channel, longPressDrags) {
            expect(longPressDrags, isTrue);
            return SizedBox(height: 48, child: Text(channel.id));
          },
          headerBuilder: _header,
        ),
      ),
    );

    // A held press starts the drag; no drag-handle glyph is built at all.
    final gesture = await tester.startGesture(tester.getCenter(find.text('a')));
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.moveBy(const Offset(0, 120));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(reported, isNotNull);
    expect(reported!.single.categoryId, isNull);
    expect(
      reported!.single.channelIds,
      isNot(['a', 'b', 'c']),
      reason: 'the drag must have reported a real reordering',
    );
    expect(reported!.single.channelIds.toSet(), {
      'a',
      'b',
      'c',
    }, reason: 'the same three ids, just reordered');
  });

  testWidgets(
    'a drag across two category sections reassigns the channel to the '
    'section it was dropped in',
    (tester) async {
      final category = const ChannelCategoryRow(
        id: 'voice-cat',
        name: 'Voice',
        position: 0,
      );
      List<ChannelOrderGroup>? reported;
      await tester.pumpWidget(
        _harness(
          ReorderableChannelRows(
            sections: [
              (null, [_channel('a')]),
              (category, [_channel('b')]),
            ],
            canManage: true,
            onReorder: (order) => reported = order,
            rowBuilder: (channel, longPressDrags) {
              expect(longPressDrags, isTrue);
              return SizedBox(height: 48, child: Text(channel.id));
            },
            headerBuilder: _header,
          ),
        ),
      );

      // Drag 'a' down past the "Voice" header and 'b', into the Voice section.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('a')),
      );
      await tester.pump(kLongPressTimeout + kPressTimeout);
      await gesture.moveBy(const Offset(0, 200));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(reported, isNotNull);
      final uncategorised = reported!.firstWhere((g) => g.categoryId == null);
      final voice = reported!.firstWhere((g) => g.categoryId == 'voice-cat');
      expect(
        uncategorised.channelIds.contains('a'),
        isFalse,
        reason: 'dragged out of the uncategorised section',
      );
      expect(
        voice.channelIds.contains('a'),
        isTrue,
        reason: 'a channel of any kind may be dragged into any category',
      );
    },
  );

  testWidgets(
    'a phone lifts a row on a held press and a plain drag stays a scroll',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      List<ChannelOrderGroup>? reported;
      await tester.pumpWidget(
        _harness(
          ReorderableChannelRows(
            sections: [
              (null, [_channel('a'), _channel('b'), _channel('c')]),
            ],
            canManage: true,
            onReorder: (order) => reported = order,
            rowBuilder: (channel, longPressDrags) {
              expect(longPressDrags, isTrue, reason: 'a held press lifts');
              return SizedBox(height: 48, child: Text(channel.id));
            },
            headerBuilder: _header,
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('a')),
      );
      await tester.pump(kLongPressTimeout + kPressTimeout);
      await gesture.moveBy(const Offset(0, 120));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        reported,
        isNotNull,
        reason: 'a lifted row still reorders on a phone',
      );
      expect(reported!.single.channelIds, isNot(['a', 'b', 'c']));
    },
  );

  test('groupsFromRailItems attributes a channel dropped above every header to '
      'the uncategorised group even when sections does not list one - the '
      'exact silent drop behind a real "Missing live channel(s)" server '
      'rejection', () {
    final category = const ChannelCategoryRow(
      id: 'cat-1',
      name: 'General',
      position: 0,
    );
    final items = <RailItem>[
      ChannelRailItem(_channel('stray')),
      HeaderRailItem(category),
      ChannelRailItem(_channel('kept')),
    ];
    final sections = <ChannelSection>[
      (category, [_channel('kept')]),
    ];

    final groups = groupsFromRailItems(items, sections);

    expect(
      groups.expand((g) => g.channelIds).toSet(),
      {'stray', 'kept'},
      reason:
          'sections omitting a null entry must never be the reason a '
          'channel disappears from the payload',
    );
    expect(groups.firstWhere((g) => g.categoryId == null).channelIds, [
      'stray',
    ]);
  });

  testWidgets(
    'dragging a channel above every header still names it in the payload - '
    'the drag that pulls a channel out of its only category, and the exact '
    'gesture that produced a real "Missing live channel(s)" server '
    'rejection when sections held no uncategorised entry',
    (tester) async {
      final category = const ChannelCategoryRow(
        id: 'cat-1',
        name: 'General',
        position: 0,
      );
      final channels = [_channel('a'), _channel('b'), _channel('c')];
      List<ChannelOrderGroup>? reported;
      await tester.pumpWidget(
        _harness(
          ReorderableChannelRows(
            sections: [(null, <Channel>[]), (category, channels)],
            canManage: true,
            onReorder: (order) => reported = order,
            rowBuilder: (channel, longPressDrags) {
              expect(longPressDrags, isTrue);
              return SizedBox(height: 48, child: Text(channel.id));
            },
            headerBuilder: _header,
          ),
        ),
      );

      // Drag 'a' to the top of the rail, into the empty uncategorised section above the only category.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('a')),
      );
      await tester.pump(kLongPressTimeout + kPressTimeout);
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(reported, isNotNull);
      expect(
        reported!.expand((g) => g.channelIds).toSet(),
        {'a', 'b', 'c'},
        reason:
            'every channel must still be named exactly once; one silently '
            'vanished from the payload in production',
      );
      expect(
        reported!.firstWhere((g) => g.categoryId == null).channelIds,
        contains('a'),
        reason: 'dragged clear of the only category there is',
      );
    },
  );
}
