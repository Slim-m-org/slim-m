// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that chosen pen style and shape kind survive across canvas reopens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('pen style and shape kind persist when reopening canvas pane', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    expect(
      container.read(canvasActiveShapeKindProvider),
      CanvasShapeKind.rectangle,
    );

    const newPen = CanvasPenStyle(colorKey: 'purple', width: 6.0);
    container.read(canvasActivePenStyleProvider.notifier).state = newPen;
    container.read(canvasActiveShapeKindProvider.notifier).state =
        CanvasShapeKind.ellipse;

    // Leave the canvas pane
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Reopen canvas pane
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    expect(container.read(canvasActivePenStyleProvider), newPen);
    expect(
      container.read(canvasActiveShapeKindProvider),
      CanvasShapeKind.ellipse,
    );
  });
}
