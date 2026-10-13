// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fullscreen: what the canvas drops, what it deliberately keeps, and the
/// three ways back out.
///
/// Driven through the whole [CanvasPane] rather than [CanvasPaneBody] alone,
/// because the two halves that could most easily be wired wrong are the ones
/// only the real pane owns: the provider the shell reads to hide the rail,
/// and the tool swap that keeps a one-finger drag from drawing in a mode
/// whose whole point is looking rather than drawing.
///
/// Every claim about the surface reclaiming the identity strip's space is
/// read off the real, laid-out `RenderBox` through `support/geometry.dart`,
/// never off whether a widget is in the tree: a bar that unmounted while
/// something else took its place would pass a presence check and fail a
/// person looking at the screen.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_bar.dart';
import 'package:slimm_app/src/screens/canvas/canvas_fullscreen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';
import 'support/geometry.dart';

/// The identity strip's own fixed height, the space fullscreen hands back.
const _barHeight = AppSizes.headerBar;

Future<void> _enterFullscreen(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More canvas actions'));
  await tester.pump();
  await tester.tap(find.text('Enter fullscreen'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the surface takes the identity strip\'s own height back, measured '
      'rather than inferred from the bar having unmounted', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    final before = tester.getRect(find.byType(CanvasSurface));
    expect(find.byType(CanvasBar), findsOneWidget);
    expectEdgeGap(
      tester,
      find.byType(CanvasSurface),
      GeometryEdge.top,
      _barHeight,
    );

    await _enterFullscreen(tester);

    expect(find.byType(CanvasBar), findsNothing);
    expectEdgeGap(tester, find.byType(CanvasSurface), GeometryEdge.top, 0);
    // The strip's height, not merely "some more": a change that dropped the bar and left a gap where it was would pass the assertion above and fail this one.
    final after = tester.getRect(find.byType(CanvasSurface));
    expect(after.height - before.height, closeTo(_barHeight, 0.5));
  });

  testWidgets(
    'entering disarms the pen, and leaving hands back the tool that was '
    'actually in use rather than the default',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);

      // A tool that is neither the pen nor the one fullscreen forces, so a fix that merely restored the default would pass nothing here.
      await tester.tap(find.bySemanticsLabel('Note'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
        CanvasTool.note,
      );

      await _enterFullscreen(tester);

      expect(
        tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
        CanvasTool.pan,
        reason: 'a one-finger drag would otherwise still place a note',
      );

      await tester.tap(find.bySemanticsLabel('Exit fullscreen'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
        CanvasTool.note,
      );
    },
  );

  testWidgets('the tool strip folds away and the way back takes its place', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    expect(find.bySemanticsLabel('Pen'), findsOneWidget);
    expect(find.bySemanticsLabel('Exit fullscreen'), findsNothing);

    await _enterFullscreen(tester);

    for (final gone in const [
      'Pen',
      'Note',
      'Eraser',
      'Undo',
      'Close canvas',
    ]) {
      expect(
        find.bySemanticsLabel(gone),
        findsNothing,
        reason: '$gone is chrome fullscreen was asked to drop',
      );
    }
    expect(find.bySemanticsLabel('Exit fullscreen'), findsOneWidget);
  });

  testWidgets('Escape leaves fullscreen, and is not bound outside it', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    // Bound only while there is something to escape from, so Escape keeps reaching whatever else would have handled it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(container.read(canvasFullscreenProvider), isNull);
    expect(find.byType(CanvasBar), findsOneWidget);

    await _enterFullscreen(tester);
    expect(container.read(canvasFullscreenProvider), 'c1');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(container.read(canvasFullscreenProvider), isNull);
    expect(find.byType(CanvasBar), findsOneWidget);
  });

  testWidgets('the way back carries a real accessible name, dumped rather '
      'than assumed from the widget', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    // Disposed inline, never through addTearDown: the binding's own handle check runs the instant the test body returns, strictly before any tearDown callback - the same ordering this project has already recorded for a pending timer.
    final handle = tester.ensureSemantics();
    await pumpCanvasPane(tester, container);
    await _enterFullscreen(tester);

    final tree = tester
        .binding
        .renderViews
        .first
        .owner!
        .semanticsOwner!
        .rootSemanticsNode!
        .toStringDeep();

    expect(tree, contains('Exit fullscreen'));
    // A label with no action behind it is a sentence a screen reader reads out and cannot act on.
    expect(
      tester.getSemantics(find.bySemanticsLabel('Exit fullscreen')),
      isSemantics(label: 'Exit fullscreen', hasTapAction: true),
    );
    handle.dispose();
  });

  testWidgets('closing the canvas clears fullscreen with it', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await _enterFullscreen(tester);
    expect(container.read(canvasFullscreenProvider), 'c1');

    // Leaving fullscreen first is the only route to Close canvas, which is the point: the two are cleared together either way.
    await tester.tap(find.bySemanticsLabel('Exit fullscreen'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Close canvas'));
    await tester.pumpAndSettle();

    expect(container.read(canvasFullscreenProvider), isNull);
  });
}
