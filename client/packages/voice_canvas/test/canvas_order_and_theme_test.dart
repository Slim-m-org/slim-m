// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas audit's ordering and theming fixes: ties paint in the server's
/// (z_index, seq) order (#2040), a provisional local z never reaches "bring
/// to front" (#2038), a stroke given up as failed comes back when its commit
/// lands (#2039), and the painters follow a theme change (#2037).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/selection_painter.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _stroke(String id, {int zIndex = 1, int seq = 1}) =>
    CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: zIndex,
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      points: const [0, 0, 10, 10],
      width: 3,
      colorKey: 'annotation',
    );

List<String> _ids(CanvasDocument document) =>
    document.paintOrder.map((slot) => document.strokeAt(slot).id).toList();

void main() {
  test('#2040 equal z-indexes paint in seq order', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    for (var seq = 200; seq >= 1; seq--) {
      document.applyPlaced(_stroke('s$seq', zIndex: 5, seq: seq));
    }
    document.refresh();
    expect(_ids(document), [for (var seq = 1; seq <= 200; seq++) 's$seq']);
  });

  test('#2038 a provisional stroke is left out of the z range', () {
    final document = CanvasDocument()
      ..applyPlaced(_stroke('a', zIndex: 1))
      ..applyPlaced(_stroke('b', zIndex: 2))
      ..applyPlaced(_stroke('mine', zIndex: provisionalLocalZIndex, seq: 0));
    expect(document.zIndexRange, (1, 2));
  });

  test('#2039 a stroke killed as failed comes back when its commit lands', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.applyPlaced(_stroke('a'));
    document.kill('a');
    document.refresh();
    expect(document.paintOrder, isEmpty);
    final before = document.objectCount.value;

    document.applyPlaced(_stroke('a', zIndex: 3, seq: 7));
    document.refresh();
    expect(_ids(document), ['a']);
    expect(document.objectCount.value, before + 1);
  });

  group('#2037 painters follow a theme change', () {
    Widget surface(CanvasDocument document, Color ink, Color outline) =>
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: ink,
            selectionOutline: outline,
            onStroke: (_) {},
          ),
        );

    T painter<T>(WidgetTester tester) => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter)
        .whereType<T>()
        .single;

    testWidgets('committed ink and the selection outline update', (
      tester,
    ) async {
      final document = CanvasDocument();
      const first = Color(0xFFE86A5C);
      const second = Color(0xFF5B8FD6);
      await tester.pumpWidget(surface(document, first, first));
      expect(painter<StrokePainter>(tester).ink, first);

      await tester.pumpWidget(surface(document, second, second));
      expect(painter<StrokePainter>(tester).ink, second);
      expect(painter<SelectionPainter>(tester).outline, second);
    });

    testWidgets('an unchanged theme keeps the same painter', (tester) async {
      final document = CanvasDocument();
      const ink = Color(0xFFE86A5C);
      await tester.pumpWidget(surface(document, ink, ink));
      final before = painter<StrokePainter>(tester);
      await tester.pumpWidget(surface(document, ink, ink));
      expect(identical(painter<StrokePainter>(tester), before), isTrue);
    });
  });
}
