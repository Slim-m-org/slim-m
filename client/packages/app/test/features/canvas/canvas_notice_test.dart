// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The board's notices: one at a time, floated just above the dock they are
/// about, and faded out once their condition clears rather than snapped away.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_call_dock.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_zoom_indicator.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_pill_surface.dart';
import 'package:slimm_app/src/widgets/status_pill.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

const _failure = 'That could not be redone.';

Future<CanvasEngine> _pane(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture();
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, board: true, tool: null);
  await pumpFrames(tester);
  return container.read(canvasEngineProvider('c1').notifier);
}

Finder _dock() => find.byWidgetPredicate((w) => w is CanvasCallDock);

double _opacityOf(WidgetTester tester, Finder text) {
  final fades = find.ancestor(
    of: text,
    matching: find.byWidgetPredicate((w) => w is FadeTransition),
  );
  if (fades.evaluate().isEmpty) return 1;
  return tester.widget<FadeTransition>(fades.first).opacity.value;
}

void main() {
  testWidgets('two notices never stack: ink still saving outranks a '
      'failure that can be dismissed', (tester) async {
    final engine = await _pane(tester);
    engine.reportError(_failure);
    surfaceDocument(tester).setUnsaved('stroke-1', unsaved: true);
    await pumpFrames(tester, frames: 20);

    expect(find.textContaining('not saved'), findsOneWidget);
    expect(find.text(_failure), findsNothing);

    surfaceDocument(tester).setUnsaved('stroke-1', unsaved: false);
    await pumpFrames(tester, frames: 20);

    expect(find.textContaining('not saved'), findsNothing);
    expect(find.text(_failure), findsOneWidget);
  });

  testWidgets('a refusal that stops the pen outranks ink still saving', (
    tester,
  ) async {
    final engine = await _pane(tester);
    final refused = canvasDrawForbiddenMessage(null);
    engine.reportError(refused);
    surfaceDocument(tester).setUnsaved('stroke-1', unsaved: true);
    await pumpFrames(tester, frames: 20);

    expect(find.text(refused), findsOneWidget);
    expect(find.textContaining('not saved'), findsNothing);
  });

  testWidgets('a canvas error is dismissed by its close button', (
    tester,
  ) async {
    final engine = await _pane(tester);
    engine.reportError(_failure);
    await pumpFrames(tester, frames: 20);

    await tester.tap(find.byKey(StatusPill.dismissKey));
    await pumpFrames(tester, frames: 20);

    expect(engine.state.error, isNull);
    expect(find.text(_failure), findsNothing);
  });

  testWidgets('a failed load offers Retry and no close, since it retries '
      'by itself', (tester) async {
    final engine = await _pane(tester);
    engine.reportError(CanvasEngine.genericLoadError);
    await pumpFrames(tester, frames: 20);

    expect(find.text(CanvasEngine.genericLoadError), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byKey(StatusPill.dismissKey), findsNothing);
  });

  testWidgets('a notice floats just above the dock, not across the top', (
    tester,
  ) async {
    final engine = await _pane(tester);
    engine.reportError(_failure);
    await pumpFrames(tester, frames: 20);

    final notice = tester.getRect(find.text(_failure));
    final dock = tester.getRect(_dock());
    expect(notice.bottom, lessThan(dock.top));
    expect(dock.top - notice.bottom, lessThan(AppSpacing.s48));
  });

  testWidgets('a notice fades out once its condition clears', (tester) async {
    final engine = await _pane(tester);
    engine.reportError(_failure);
    await pumpFrames(tester, frames: 20);
    expect(_opacityOf(tester, find.text(_failure)), 1);

    engine.reportError(null);
    await tester.pump();
    await tester.pump(AppMotion.base ~/ 2);

    expect(find.text(_failure), findsOneWidget);
    expect(_opacityOf(tester, find.text(_failure)), inExclusiveRange(0, 1));

    await pumpFrames(tester, frames: 20);
    expect(find.text(_failure), findsNothing);
  });

  testWidgets('a notice coming and going moves none of the board controls', (
    tester,
  ) async {
    final engine = await _pane(tester);
    final dock = tester.getRect(_dock());
    final zoom = tester.getRect(find.text('100%'));

    engine.reportError(_failure);
    await pumpFrames(tester, frames: 20);

    expect(tester.getRect(_dock()), dock);
    expect(tester.getRect(find.text('100%')), zoom);
  });

  testWidgets('hidden ink is said beside the zoom readout it depends on', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(800, 600));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Stack(
              children: [
                CanvasZoomIndicator(
                  document: document,
                  tokens: AppTokens.dark,
                  onFit: () {},
                  onBringIn: () {},
                  truncated: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester, frames: 20);

    final chip = tester.getRect(find.text('Some ink hidden - zoom in'));
    final zoom = tester.getRect(find.text('100%'));
    expect(chip.left, greaterThan(zoom.right));
    expect(chip.center.dy, moreOrLessEquals(zoom.center.dy, epsilon: 1));

    final before = document.camera.zoom;
    await tester.tap(find.text('Some ink hidden - zoom in'));
    await tester.pump();
    expect(document.camera.zoom, greaterThan(before));
  });

  testWidgets('the board chips keep a gap when a narrow pane wraps them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(470, 600));
    document.outsideBoardCount.value = 3;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 470,
                height: 600,
                child: Stack(
                  children: [
                    CanvasZoomIndicator(
                      document: document,
                      tokens: AppTokens.dark,
                      onFit: () {},
                      onBringIn: () {},
                      truncated: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester, frames: 20);

    final outside = _pillAround(tester, '3 outside the board - bring in');
    final hidden = _pillAround(tester, 'Some ink hidden - zoom in');
    expect(hidden.top, greaterThan(outside.top));
    expect(hidden.top - outside.bottom, AppSpacing.s8);
    expect(hidden.left, outside.left);
  });
}

Rect _pillAround(WidgetTester tester, String label) => tester.getRect(
  find
      .ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is CanvasPillSurface),
      )
      .first,
);
