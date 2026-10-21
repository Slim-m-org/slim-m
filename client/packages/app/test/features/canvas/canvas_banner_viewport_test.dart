// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An error banner lies over the board instead of taking height from it, so
/// the fitted board does not re-zoom when one appears.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('a banner leaves the board viewport the same size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true);
    await tester.pumpAndSettle();
    final before = surfaceDocument(tester).viewport;

    container
        .read(canvasEngineProvider('c1').notifier)
        .reportError('That could not be saved.');
    await tester.pumpAndSettle();

    expect(find.text('That could not be saved.'), findsOneWidget);
    expect(surfaceDocument(tester).viewport, before);
  });
}
