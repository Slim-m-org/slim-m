// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the compact layout's edge-swipe route to the channel rail:
/// reachable at phone width, absent at expanded width (the rail is already
/// docked there so a drawer would be redundant), dismissible by a scrim tap
/// or by dragging it closed, closes itself once a row inside it picks a
/// different channel, carried further opens the full-screen channel list, and
/// withheld while the canvas is open, since the canvas claims the same screen
/// edge for its own pan gesture.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/widgets/channel_rail.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'ui_snapshot_support.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _pumpAtWidth(
  WidgetTester tester,
  double width, {
  String location = '/channels/c-general',
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer();
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

/// A drag starting inside the default 20px edge strip, well past the
/// fling threshold, settled to whichever end it lands on.
Future<void> _dragFromLeftEdge(WidgetTester tester) async {
  await tester.dragFrom(const Offset(5, 300), const Offset(300, 0));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an edge drag reveals the rail at compact width', (tester) async {
    final fixture = await _pumpAtWidth(tester, 500);
    expect(find.byType(ChannelRail), findsNothing);

    await _dragFromLeftEdge(tester);

    expect(find.byType(ChannelRail), findsOneWidget);
    expect(
      find.text('design'),
      findsOneWidget,
      reason: 'the second channel only ever appears in the rail itself',
    );

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('the edge drag opens nothing extra at expanded width', (
    tester,
  ) async {
    final fixture = await _pumpAtWidth(tester, 1400);
    expect(find.byType(ChannelRail), findsOneWidget); // already docked

    await _dragFromLeftEdge(tester);

    expect(
      find.byType(Drawer),
      findsNothing,
      reason: 'the rail is already on screen, so nothing offers a drawer',
    );
    expect(find.byType(ChannelRail), findsOneWidget);

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('tapping outside the open rail dismisses it', (tester) async {
    final fixture = await _pumpAtWidth(tester, 500);
    await _dragFromLeftEdge(tester);
    expect(find.byType(ChannelRail), findsOneWidget);

    // Past the drawer's own width (304 by default), inside the scrim.
    await tester.tapAt(const Offset(450, 300));
    await tester.pumpAndSettle();

    expect(find.byType(ChannelRail), findsNothing);

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('dragging the rail closed dismisses it', (tester) async {
    final fixture = await _pumpAtWidth(tester, 500);
    await _dragFromLeftEdge(tester);
    expect(find.byType(ChannelRail), findsOneWidget);

    await tester.dragFrom(const Offset(200, 300), const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.byType(ChannelRail), findsNothing);

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('selecting a different channel from the open rail closes it', (
    tester,
  ) async {
    final fixture = await _pumpAtWidth(tester, 500);
    await _dragFromLeftEdge(tester);
    expect(find.text('tokens, type and the shell'), findsNothing);

    await tester.tap(find.text('design'));
    await tester.pumpAndSettle();

    expect(
      find.byType(ChannelRail),
      findsNothing,
      reason:
          "a row's own tap only navigates - this widget has to notice "
          'the selection changed underneath it and close itself',
    );
    expect(find.text('tokens, type and the shell'), findsOneWidget);

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('the rail is withheld from the scaffold while the canvas is open', (
    tester,
  ) async {
    // Not a real drag: over a live canvas that draws a stroke this fixture's fake server has no answer for, so the gate itself is asserted directly.
    final fixture = await _pumpAtWidth(tester, 500);
    fixture.container.read(canvasOpenProvider.notifier).state = 'c-general';
    await tester.pumpAndSettle();
    expect(find.byType(CanvasSurface), findsOneWidget);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(
      scaffold.drawer,
      isNull,
      reason: 'the canvas claims the same edge for its own pan gesture',
    );

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('carrying the swipe further opens the full-screen list', (
    tester,
  ) async {
    // Backlog: "no way to swipe it further to return to the initial full screen channel view".
    final fixture = await _pumpAtWidth(tester, 500);
    await _dragFromLeftEdge(tester);
    expect(find.byType(Drawer), findsOneWidget);

    await tester.dragFrom(const Offset(120, 300), const Offset(140, 0));
    await tester.pumpAndSettle();

    expect(
      find.byType(Drawer),
      findsNothing,
      reason: 'the drawer gives way to the list it was a peek at',
    );
    expect(find.byType(ChannelRail), findsOneWidget);

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('a short carry leaves the drawer where it is', (tester) async {
    final fixture = await _pumpAtWidth(tester, 500);
    await _dragFromLeftEdge(tester);

    // Under the commit distance: a nudge is not a decision.
    await tester.dragFrom(const Offset(120, 300), const Offset(30, 0));
    await tester.pumpAndSettle();

    expect(find.byType(Drawer), findsOneWidget);

    await teardownFixture(tester, fixture.container, fixture.db);
  });
}
