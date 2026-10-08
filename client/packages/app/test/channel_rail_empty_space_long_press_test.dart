// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// At phone width a held press on the rail's blank space opens Create channel
/// and Create category (desktop-vs-mobile.md rule 3: a pointer affordance has
/// a long-press equivalent), without disturbing a row's own held press, its
/// hold-then-move drag, or a scroll.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/channel_rail.dart';
import 'package:slimm_app/src/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/widgets/rail_drag_lift.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _pump(
  WidgetTester tester, {
  int extraChannels = 0,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer();
  if (extraChannels > 0) {
    final store = await fixture.container.read(storeProvider.future);
    await store.upsertChannels([
      for (var i = 0; i < extraChannels; i++)
        api.Channel(id: 'x-$i', name: 'extra-$i', kind: 'text', createdAt: 0),
    ]);
  }
  final router = GoRouter(
    initialLocation: Routes.channel('c-general'),
    routes: [
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) => const Scaffold(body: ChannelRail()),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

Future<void> _hold(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at);
  await tester.pump(kLongPressTimeout + kPressTimeout);
  await gesture.up();
  await tester.pumpAndSettle();
}

Offset _belowLastRow(WidgetTester tester) {
  final sections = tester.getRect(find.byType(ChannelCategorySections));
  return Offset(195, sections.bottom + 30);
}

void main() {
  testWidgets('a long press under the last row opens both create items', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    expect(find.text('Create channel...'), findsNothing);

    await _hold(tester, _belowLastRow(tester));

    expect(find.text('Create channel...'), findsOneWidget);
    expect(find.text('Create category...'), findsOneWidget);
    expect(find.text('Move up'), findsNothing);
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('a long press on a row opens only that row menu', (tester) async {
    final fixture = await _pump(tester);

    await _hold(tester, tester.getCenter(find.text('general')));

    expect(find.text('Move up'), findsOneWidget);
    expect(find.text('Create channel...'), findsNothing);
    expect(find.text('Create category...'), findsNothing);
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('a hold then a move still lifts the row and opens no menu', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('general')),
    );
    await tester.pump(kLongPressTimeout + kPressTimeout);
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(RailDragLift), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Create channel...'), findsNothing);
    expect(find.text('Move up'), findsNothing);
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('a vertical drag on a long list scrolls and opens no menu', (
    tester,
  ) async {
    final fixture = await _pump(tester, extraChannels: 40);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(200));

    final gesture = await tester.startGesture(const Offset(195, 600));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, greaterThan(100));
    expect(find.text('Create channel...'), findsNothing);
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets(
    'scrolled to the end of a long list the band is still pressable',
    (tester) async {
      final fixture = await _pump(tester, extraChannels: 40);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();

      final viewport = tester.getRect(find.byType(CustomScrollView));
      await _hold(tester, Offset(195, viewport.bottom - 20));

      expect(find.text('Create channel...'), findsOneWidget);
      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );
}
