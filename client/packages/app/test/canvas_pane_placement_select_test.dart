// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Report 3: placing a new object leaves it selected, with resize handles
/// already live, and the surface already in Move mode - no separate tool
/// switch first. Covers the shape and note tools driven through the full
/// pane; `canvas_image_paste.dart`'s own `onPlaced` signature change is
/// exercised by the identical `_selectPlaced` call the paste path now shares
/// with these two, so a regression in the shared helper fails here too.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets(
    'placing a shape selects it and switches to Move, ready to resize',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Shape'));
      await tester.pump();

      final point = screenFor(tester, const Offset(50, 50));
      final gesture = await tester.startGesture(point);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(fixture.posted, hasLength(1));
      expect(fixture.posted.single['kind'], 'shape');
      final placedId = fixture.posted.single['id'] as String;

      expect(surfaceDocument(tester).selectedObjectId.value, placedId);
      expect(
        tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
        CanvasTool.pan,
        reason: 'resizing must not need a manual switch to Move first',
      );
    },
  );

  testWidgets('placing a second shape right after does not carry the first '
      'selection forward by accident', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Shape'));
    await tester.pump();
    var gesture = await tester.startGesture(
      screenFor(tester, const Offset(50, 50)),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final firstId = fixture.posted.single['id'] as String;

    // Switching back to Shape, since a placement now leaves the surface on Move.
    await tester.tap(find.bySemanticsLabel('Shape'));
    await tester.pump();
    gesture = await tester.startGesture(
      screenFor(tester, const Offset(200, 200)),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(fixture.posted, hasLength(2));
    final secondId = fixture.posted.last['id'] as String;
    expect(secondId, isNot(firstId));
    expect(surfaceDocument(tester).selectedObjectId.value, secondId);
  });

  testWidgets(
    'placing a note selects it and switches to Move, ready to resize',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Note'));
      await tester.pump();
      final gesture = await tester.startGesture(
        screenFor(tester, const Offset(50, 50)),
      );
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'a note');
      await tester.pump();
      await tester.tap(find.text('Add note'));
      await tester.pumpAndSettle();

      expect(fixture.posted, hasLength(1));
      expect(fixture.posted.single['kind'], 'note');
      final placedId = fixture.posted.single['id'] as String;

      expect(surfaceDocument(tester).selectedObjectId.value, placedId);
      expect(
        tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
        CanvasTool.pan,
      );
    },
  );

  testWidgets('cancelling the note sheet places nothing and selects nothing', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Note'));
    await tester.pump();
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(50, 50)),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    // Cancelling is a bare back-navigation, the same route every other sheet in this app cancels through.
    Navigator.of(tester.element(find.byType(TextField))).pop();
    await tester.pumpAndSettle();

    expect(fixture.posted, isEmpty);
    expect(surfaceDocument(tester).selectedObjectId.value, isNull);
  });
}
