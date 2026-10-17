// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the handle at the rail's edge (#256's toggle, a plain click
/// since backlog item 54): tap it to switch the rail between full and
/// compact width. Compact is still the rail - every channel name stays - so
/// "collapsed" is asserted as a width, never as the rail being gone.
///
/// The header's own "the button is gone" regression lives beside its other
/// tests, in `channel_header_test.dart`, which already carries the harness a
/// bare `ChannelHeader` needs (a signed-in session and a pin-list stub).
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_drawer.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_drag_handle.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../home_shell_harness.dart';

double _railWidth(WidgetTester tester) =>
    tester.getSize(find.byType(ChannelRail)).width;

void main() {
  testWidgets('clicking the handle narrows the rail to compact, and clicking '
      'it again widens it back', (tester) async {
    final s = setup();
    await pumpAtWidth(tester, s.container, 1400);
    expect(_railWidth(tester), ChannelRail.expandedWidth);

    await tester.tap(find.byType(RailDragHandle));
    await tester.pumpAndSettle();
    expect(_railWidth(tester), ChannelRail.compactWidth);

    await tester.tap(find.byType(RailDragHandle));
    await tester.pumpAndSettle();
    expect(_railWidth(tester), ChannelRail.expandedWidth);

    await teardown(tester, s.container, s.db);
  });

  testWidgets('the visible line is a plain hairline divider, never a filled '
      'bar', (tester) async {
    final s = setup();
    await pumpAtWidth(tester, s.container, 1400);

    final divider = tester.widget<VerticalDivider>(
      find.byType(VerticalDivider),
    );
    expect(
      divider.width,
      1,
      reason:
          'backlog item 54: a thick grab bar reads as a resize handle, '
          'not a toggle',
    );

    await teardown(tester, s.container, s.db);
  });

  testWidgets(
    'open, the divider reserves only its own hairline width in the row - '
    'nothing is held off the boundary to make room for a wider hit region',
    (tester) async {
      final s = setup();
      await pumpAtWidth(tester, s.container, 1400);

      final size = tester.getSize(find.byType(RailDragHandle));
      expect(
        size.width,
        1,
        reason:
            'backlog item 58: a reserved gap either side of the line - '
            'colour-matched or not - is what this fix removes',
      );

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'clicking just left of the line still toggles - the hit region reaches '
    "back into the rail's own already-blank edge rather than the reserved "
    'gap this replaced',
    (tester) async {
      final s = setup();
      await pumpAtWidth(tester, s.container, 1400);

      final line = tester.getCenter(find.byType(RailDragHandle));
      await tester.tapAt(line - const Offset(6, 0));
      await tester.pumpAndSettle();
      expect(_railWidth(tester), ChannelRail.compactWidth);

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'clicking just right of the line does not toggle - a message row is '
    'opaque edge to edge in the transcript, so the hit region must not '
    'reach there',
    (tester) async {
      final s = setup();
      await pumpAtWidth(tester, s.container, 1400);

      final line = tester.getCenter(find.byType(RailDragHandle));
      await tester.tapAt(line + const Offset(6, 0));
      await tester.pumpAndSettle();
      expect(_railWidth(tester), ChannelRail.expandedWidth);

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'clicking further left than the rail already leaves blank does not '
    "toggle - the cap that keeps this from ever reaching the footer's "
    'settings button, which sits exactly at that edge',
    (tester) async {
      final s = setup();
      await pumpAtWidth(tester, s.container, 1400);

      final line = tester.getCenter(find.byType(RailDragHandle));
      await tester.tapAt(line - const Offset(10, 0));
      await tester.pumpAndSettle();
      expect(_railWidth(tester), ChannelRail.expandedWidth);

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'open, the semantics tree carries this control\'s label exactly once - '
    'dumped rather than inferred, since a leaked action bled onto an '
    'unrelated ancestor once before (backlog item 54)',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final s = setup();
      await pumpAtWidth(tester, s.container, 1400);

      final dump = tester
          .binding
          .renderViews
          .first
          .owner!
          .semanticsOwner!
          .rootSemanticsNode!
          .toStringDeep();
      expect('Narrow channel list'.allMatches(dump).length, 1, reason: dump);
      expect(find.bySemanticsLabel('Narrow channel list'), findsOneWidget);

      semantics.dispose();
      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'compact, the rail keeps every channel name - no icon strip - and the '
    'semantic action a screen reader or the keyboard would use widens it '
    'again',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final s = setup(httpClient: quietClient(), signedIn: true);
      await MessageStore(s.db).upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
      ]);
      await pumpAtWidth(tester, s.container, 1400);

      s.container.read(channelRailExpandedProvider.notifier).state = false;
      await tester.pumpAndSettle();
      expect(_railWidth(tester), ChannelRail.compactWidth);
      expect(
        find.descendant(
          of: find.byType(ChannelRail),
          matching: find.text('general'),
        ),
        findsOneWidget,
        reason: 'the owner asked for a smaller rail, not a strip of icons',
      );

      final node = tester.getSemantics(
        find.bySemanticsLabel('Widen channel list'),
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.tap,
          nodeId: node.id,
          viewId: tester.view.viewId,
        ),
      );
      await tester.pumpAndSettle();
      expect(_railWidth(tester), ChannelRail.expandedWidth);

      semantics.dispose();
      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets('compact, the footer drops only its name line: presence, mic, '
      'deafen and settings all stay', (tester) async {
    final semantics = tester.ensureSemantics();
    final s = setup(httpClient: quietClient(), signedIn: true);
    await pumpAtWidth(tester, s.container, 1400);
    await tester.pumpAndSettle();
    final footer = find.byType(RailUserFooter);
    expect(
      find.descendant(of: footer, matching: find.text('Bob')),
      findsOneWidget,
    );

    s.container.read(channelRailExpandedProvider.notifier).state = false;
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: footer, matching: find.text('Bob')),
      findsNothing,
    );
    for (final label in [
      RegExp(r'^(Mute|Unmute)$'),
      RegExp(r'^Deafen$'),
      RegExp(r'^Personal settings'),
    ]) {
      expect(
        find.descendant(of: footer, matching: find.bySemanticsLabel(label)),
        findsOneWidget,
        reason: label.pattern,
      );
    }
    expect(tester.takeException(), isNull, reason: 'no overflow at 200px');

    semantics.dispose();
    await teardown(tester, s.container, s.db);
  });

  testWidgets('compact survives a channel switch, the same session-only '
      'persistence the provider already had', (tester) async {
    final s = setup();
    await pumpAtWidth(tester, s.container, 1400);

    await tester.tap(find.byType(RailDragHandle));
    await tester.pumpAndSettle();
    expect(_railWidth(tester), ChannelRail.compactWidth);

    // A fresh pump, as a channel switch causes, must not readopt the default.
    await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');
    expect(_railWidth(tester), ChannelRail.compactWidth);

    await teardown(tester, s.container, s.db);
  });

  testWidgets(
    "a real channel row's own right edge never falls inside the divider's "
    "widened reach - the two are pinned to the same AppSpacing.s8, and "
    "channel_rail.dart's own row-list padding is a bare literal 8 with "
    "nothing tying it to that token",
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
      await pumpAtWidth(tester, s.container, 1400);
      await tester.pumpAndSettle();

      final railRect = tester.getRect(find.byType(ChannelRail));
      final rowRect = tester.getRect(find.byType(AppListRow).first);
      final reachLeftEdge = railRect.right - AppSpacing.s8;

      expect(
        rowRect.right,
        lessThanOrEqualTo(reachLeftEdge),
        reason:
            "if channel_rail.dart's own row padding ever drifts from "
            "AppSpacing.s8, a real row's own tap target would sit under "
            "the divider's widened hit area and lose its own right edge "
            'to a rail-collapse tap instead of a channel switch',
      );

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'the compact drawer from #301 is untouched: no rail handle at compact '
    'width, and the edge-swipe drawer still opens the rail',
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
      await pumpAtWidth(tester, s.container, 500, location: '/channels/c1');
      expect(
        find.byType(RailDragHandle),
        findsNothing,
        reason: 'compact never docks the rail, so there is no edge to click',
      );

      // Off-screen until dragged (#301's own suite covers the drag itself).
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.drawer, isA<CompactChannelRailDrawer>());

      await teardown(tester, s.container, s.db);
    },
  );
}
