// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Report 3 in the backlog channel, in the owner's own words: "when drawing
/// shapes as I drag a rectangle to select its size, I don't see it until I
/// let go of click" - the shape tool sized nothing live during a drag and
/// always placed its fixed default box regardless of how far the pointer
/// moved. `DraftShape`/`DraftShapePainter` are `DraftStroke`/`DraftPainter`'s
/// own sibling for this tool: a live screen-space preview while the pointer
/// is down, and the dragged box's own world-space size handed back through
/// [ShapePlaced] once it lifts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

DraftShapePainter _shapeDraftPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((c) => c.painter)
    .whereType<DraftShapePainter>()
    .single;

void main() {
  testWidgets(
    'a rectangle drag paints a live preview before the pointer lifts, then '
    'places at the dragged size',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      Offset? placedAt;
      Size? placedSize;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.shape,
            onStroke: (_) {},
            onShapePlace: (world, size) {
              placedAt = world;
              placedSize = size;
            },
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(120, 80));
      await tester.pump();

      expect(
        _shapeDraftPainter(tester).draft.rect,
        const Rect.fromLTWH(20, 20, 100, 60),
        reason: 'the box being dragged must be visible before release',
      );
      expect(placedAt, isNull, reason: 'not yet - the pointer is still down');

      await gesture.up();
      await tester.pump();

      expect(_shapeDraftPainter(tester).draft.rect, isNull);
      expect(placedAt, const Offset(70, 50));
      expect(placedSize, const Size(100, 60));
    },
  );

  testWidgets(
    'a plain tap with no real drag still places the fixed default size',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      Offset? placedAt;
      Size? placedSize = const Size(1, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.shape,
            onStroke: (_) {},
            onShapePlace: (world, size) {
              placedAt = world;
              placedSize = size;
            },
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(40, 40));
      await gesture.up();
      await tester.pump();

      expect(placedAt, const Offset(40, 40));
      expect(
        placedSize,
        isNull,
        reason: 'null tells the caller to use its own fixed default box',
      );
    },
  );

  testWidgets('an ellipse drag previews an ellipse, not a rectangle', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.shape,
          shapeKind: CanvasShapeKind.ellipse,
          onStroke: (_) {},
          onShapePlace: (_, __) {},
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(80, 60));
    await tester.pump();

    expect(_shapeDraftPainter(tester).draft.kind, CanvasShapeKind.ellipse);
    await gesture.up();
  });

  testWidgets(
    'a second pointer cancels a live shape preview along with the placement',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var placed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.shape,
            onStroke: (_) {},
            onShapePlace: (_, __) => placed++,
          ),
        ),
      );
      await tester.pump();

      final first = await tester.startGesture(const Offset(20, 20));
      await first.moveTo(const Offset(80, 60));
      await tester.pump();
      expect(_shapeDraftPainter(tester).draft.rect, isNotNull);

      final second = await tester.startGesture(const Offset(200, 200));
      await tester.pump();
      expect(
        _shapeDraftPainter(tester).draft.rect,
        isNull,
        reason: 'a pinch starting must drop the preview immediately',
      );

      await first.up();
      await second.up();
      await tester.pump();

      expect(placed, 0);
    },
  );
}
