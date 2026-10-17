// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone shell's drawers follow the finger: a drag from the left edge
/// moves the rail by exactly the drag distance from the first pixel, settles
/// by distance and speed on release, and behaves the same for a mouse in a
/// narrow desktop window. The owner's words: "Gesture swiping out the channel
/// view does not do anything until I reach far enough, I'd rather it follow my
/// finger and if I don't drag it enough it goes back".
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/widgets/drawer_edge_drag.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

const _screen = Size(390, 844);

Future<({ProviderContainer container, SlimmDatabase db})> _pump(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(
          Brightness.dark,
          AppTokens.dark,
        ).copyWith(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        routerConfig: fixtureRouter('/channels/c-general'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

/// A finger that goes down at [from], travels [dx] in 4px steps, and is still
/// down when this returns, so the caller can measure mid-drag.
Future<TestGesture> _holdAt(
  WidgetTester tester,
  Offset from,
  double dx, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final gesture = await tester.startGesture(from, kind: kind);
  final step = dx.sign * 4;
  for (var travelled = 0.0; travelled.abs() < dx.abs(); travelled += step) {
    await gesture.moveBy(Offset(step, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  return gesture;
}

/// Where the drawer's leading edge is: negative while it is mostly off-screen.
double _railLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byType(Drawer)).dx;

double _scrimAlpha(WidgetTester tester) => tester
    .widgetList<ColoredBox>(find.byType(ColoredBox))
    .map((box) => box.color)
    .where((c) => c.r == 0 && c.g == 0 && c.b == 0 && c.a > 0)
    .fold(0.0, (a, c) => c.a > a ? c.a : a);

Future<void> _release(WidgetTester tester, TestGesture gesture) async {
  await tester.pump(const Duration(milliseconds: 300));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    final kind = platform == TargetPlatform.linux
        ? PointerDeviceKind.mouse
        : PointerDeviceKind.touch;
    group('$platform', () {
      testWidgets('the rail moves with the finger from the first pixel', (
        tester,
      ) async {
        final fixture = await _pump(tester, platform: platform);
        final gesture = await tester.startGesture(
          const Offset(6, 300),
          kind: kind,
        );
        var travelled = 0.0;
        final width = 304.0;
        for (final mark in [20.0, 80.0, 200.0]) {
          while (travelled < mark) {
            await gesture.moveBy(const Offset(4, 0));
            await tester.pump(const Duration(milliseconds: 16));
            travelled += 4;
          }
          expect(
            _railLeft(tester),
            closeTo(mark - width, 1.5),
            reason: 'rail left edge after $mark px of drag',
          );
        }
        await gesture.up();
        await tester.pumpAndSettle();
        await teardownFixture(tester, fixture.container, fixture.db);
      });

      testWidgets('the scrim darkens in step with the drag', (tester) async {
        final fixture = await _pump(tester, platform: platform);
        final gesture = await _holdAt(
          tester,
          const Offset(6, 300),
          60,
          kind: kind,
        );
        final early = _scrimAlpha(tester);
        await gesture.moveBy(const Offset(4, 0));
        for (var i = 0; i < 35; i++) {
          await gesture.moveBy(const Offset(4, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        final later = _scrimAlpha(tester);
        expect(early, greaterThan(0));
        expect(later, greaterThan(early));
        await gesture.up();
        await tester.pumpAndSettle();
        await teardownFixture(tester, fixture.container, fixture.db);
      });

      testWidgets('releasing short of halfway slides it back shut', (
        tester,
      ) async {
        final fixture = await _pump(tester, platform: platform);
        final gesture = await _holdAt(
          tester,
          const Offset(6, 300),
          100,
          kind: kind,
        );
        expect(find.byType(ChannelRail), findsOneWidget);
        await _release(tester, gesture);
        expect(find.byType(ChannelRail), findsNothing);
        await teardownFixture(tester, fixture.container, fixture.db);
      });

      testWidgets('releasing past halfway settles it open', (tester) async {
        final fixture = await _pump(tester, platform: platform);
        final gesture = await _holdAt(
          tester,
          const Offset(6, 300),
          200,
          kind: kind,
        );
        await _release(tester, gesture);
        expect(find.byType(ChannelRail), findsOneWidget);
        expect(_railLeft(tester), closeTo(0, 0.5));
        await teardownFixture(tester, fixture.container, fixture.db);
      });

      testWidgets('a short fast fling opens it', (tester) async {
        final fixture = await _pump(tester, platform: platform);
        await tester.flingFrom(const Offset(6, 300), const Offset(60, 0), 1500);
        await tester.pumpAndSettle();
        expect(find.byType(ChannelRail), findsOneWidget);
        expect(_railLeft(tester), closeTo(0, 0.5));
        await teardownFixture(tester, fixture.container, fixture.db);
      });

      testWidgets('a drag that starts mid-content moves nothing', (
        tester,
      ) async {
        final fixture = await _pump(tester, platform: platform);
        final gesture = await _holdAt(
          tester,
          const Offset(195, 300),
          120,
          kind: kind,
        );
        expect(find.byType(Drawer), findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(ChannelRail), findsNothing);
        await teardownFixture(tester, fixture.container, fixture.db);
      });

      testWidgets(
        'an open rail follows a leftward drag and closes by distance',
        (tester) async {
          final fixture = await _pump(tester, platform: platform);
          await tester.flingFrom(
            const Offset(6, 300),
            const Offset(200, 0),
            1500,
          );
          await tester.pumpAndSettle();
          expect(_railLeft(tester), closeTo(0, 0.5));

          final gesture = await _holdAt(
            tester,
            const Offset(300, 500),
            -80,
            kind: kind,
          );
          expect(_railLeft(tester), closeTo(-80, 6));
          await _release(tester, gesture);
          expect(
            _railLeft(tester),
            closeTo(0, 0.5),
            reason: 'under halfway springs back open',
          );

          final far = await _holdAt(
            tester,
            const Offset(300, 500),
            -200,
            kind: kind,
          );
          await _release(tester, far);
          expect(find.byType(ChannelRail), findsNothing);
          await teardownFixture(tester, fixture.container, fixture.db);
        },
      );

      testWidgets('the members drawer follows a drag from the right edge', (
        tester,
      ) async {
        final fixture = await _pump(tester, platform: platform);
        final gesture = await _holdAt(
          tester,
          Offset(_screen.width - 6, 300),
          -80,
          kind: kind,
        );
        final left = tester.getTopLeft(find.byType(Drawer)).dx;
        // The framework scales the first, pre-slop delta by its default 304 rather than this narrower drawer's width, a constant lag of a few px.
        expect(left, closeTo(_screen.width - 80, 6));
        await gesture.up();
        await tester.pumpAndSettle();
        await teardownFixture(tester, fixture.container, fixture.db);
      });

      testWidgets('reduce motion still settles open and shut', (tester) async {
        final fixture = await _pump(
          tester,
          platform: platform,
          reduceMotion: true,
        );
        final gesture = await _holdAt(
          tester,
          const Offset(6, 300),
          200,
          kind: kind,
        );
        await _release(tester, gesture);
        expect(_railLeft(tester), closeTo(0, 0.5));
        final close = await _holdAt(
          tester,
          const Offset(300, 500),
          -200,
          kind: kind,
        );
        await _release(tester, close);
        expect(find.byType(ChannelRail), findsNothing);
        await teardownFixture(tester, fixture.container, fixture.db);
      });
    });
  }

  testWidgets('the edge zone sits past the system gesture inset', (
    tester,
  ) async {
    late double plain;
    late double withInset;
    Widget probe(EdgeInsets insets, void Function(double) out) => MediaQuery(
      data: MediaQueryData(systemGestureInsets: insets),
      child: Builder(
        builder: (context) {
          out(drawerEdgeDragWidth(context));
          return const SizedBox();
        },
      ),
    );
    await tester.pumpWidget(probe(EdgeInsets.zero, (w) => plain = w));
    await tester.pumpWidget(
      probe(const EdgeInsets.only(left: 30, right: 30), (w) => withInset = w),
    );
    expect(plain, kDrawerEdgeZoneWidth);
    expect(withInset, 30 + kDrawerEdgeZoneWidth);
  });
}
