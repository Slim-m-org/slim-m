// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Snapping while dragging a canvas object with the select tool: the
/// committed geometry lines up with a neighbour, and Alt moves freely.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  Future<void> dragFirstImage(WidgetTester tester, {required bool alt}) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasImageJson('a', x: 400), canvasImageJson('b', x: 500)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(415, 15)),
    );
    await gesture.moveTo(screenFor(tester, const Offset(502, 17)));
    await gesture.up();
    await tester.pumpAndSettle();
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  }

  testWidgets('a dragged image commits aligned to its neighbour', (
    tester,
  ) async {
    await dragFirstImage(tester, alt: false);
    final bounds = surfaceDocument(tester).objectBounds('a')!;
    expect(bounds.x, 490, reason: 'left edge lands on the neighbour left edge');
    expect(bounds.y, 10, reason: 'top edge lands on the neighbour top edge');
  });

  testWidgets('holding Alt moves the image freely', (tester) async {
    await dragFirstImage(tester, alt: true);
    final bounds = surfaceDocument(tester).objectBounds('a')!;
    expect(bounds.x, 487);
    expect(bounds.y, 12);
  });
}
