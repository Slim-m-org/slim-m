// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Audit lane fixes: the topmost object decides a hit, an ellipse is measured exactly, and stale painters and tables are refreshed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_hit_probes.dart';

CanvasStrokeInput _note(String id, double x, int z, {String? author}) =>
    CanvasStrokeInput(
      id: id,
      seq: z,
      zIndex: z,
      x: x,
      y: 0,
      w: 100,
      h: 100,
      points: const [],
      width: 2,
      colorKey: 'note',
      kind: CanvasObjectKind.note,
      authorId: author,
    );

CanvasStrokeInput _ellipse(double w, double h) => CanvasStrokeInput(
      id: 'e',
      seq: 1,
      zIndex: 1,
      x: 0,
      y: 0,
      w: w,
      h: h,
      points: const [],
      width: 2,
      colorKey: 'shape',
      kind: CanvasObjectKind.shape,
      shapeKind: CanvasShapeKind.ellipse,
    );

CanvasStrokeInput _piece(String id, int seq) => CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: seq,
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      points: const [0, 0, 10, 10],
      width: 3,
      colorKey: 'ink',
      groupId: 'g',
    );

void main() {
  CanvasDocument docWith(List<CanvasStrokeInput> inputs) {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    inputs.forEach(document.applyPlaced);
    return document..refresh();
  }

  group('g-client-3-1 the topmost object decides', () {
    test('a refused object on top hides the one beneath it', () {
      final document = docWith([_note('low', 0, 1), _note('top', 0, 2)]);
      bool allowed(CanvasStroke s) => s.id != 'top';

      expect(
        hitTestTopmost(document, const Offset(50, 50), allowed: allowed),
        isNull,
      );
      expect(
        boxHitAt(document, const Offset(50, 50), allowed: (s) => true),
        'top',
      );
    });

    test('fallThrough lets the walk reach the one beneath', () {
      final document = docWith([_note('low', 0, 1), _note('top', 0, 2)]);

      expect(
        hitTestTopmost(
          document,
          const Offset(50, 50),
          fallThrough: true,
          allowed: (s) => s.id != 'top',
        ),
        'low',
      );
    });
  });

  group('g-client-3-2 ellipse distance', () {
    test('a thin wide ellipse is not hit well past its slop', () {
      final document = docWith([_ellipse(1000, 2)]);
      // Outline top is at y=0; 8 units above is past width/2 + 4.
      expect(boxHitAt(document, const Offset(500, -8)), isNull);
      expect(boxHitAt(document, const Offset(500, -4)), 'e');
      expect(boxHitAt(document, const Offset(500, 3)), 'e');
    });

    test('a circle is measured by its radius at several points', () {
      final document = docWith([_ellipse(200, 200)]);
      expect(boxHitAt(document, const Offset(100, 100)), isNull);
      expect(boxHitAt(document, const Offset(100, 20)), isNull);
      expect(boxHitAt(document, const Offset(100, 4)), 'e');
      expect(boxHitAt(document, const Offset(185, 185)), isNull);
      expect(boxHitAt(document, const Offset(171, 171)), 'e');
    });
  });

  group('client-061-A-3 group slot table', () {
    test('freed pieces leave the group table', () {
      final document = docWith([_piece('a', 1), _piece('b', 2)]);
      expect(document.debugGroupSlotCount, 2);

      document.removeObject('a');
      expect(document.debugGroupSlotCount, 1);
      expect(document.groupOf('b'), ['b']);
      document.removeObject('b');
      expect(document.debugGroupSlotCount, 0);
    });
  });

  group('client-061-A-2 settled ids', () {
    test('entries past the late-frame window are dropped', () {
      final document = docWith([_note('a', 0, 1)]);
      final previews = RemoteObjectPreviews(document);
      final t0 = DateTime(2026);
      for (var i = 0; i < 50; i++) {
        previews.settle('o$i', now: t0);
      }
      expect(previews.debugSettledCount, 50);

      previews.settle('late', now: t0.add(objectPreviewLateFrameWindow));
      expect(previews.debugSettledCount, 1);
    });
  });

  group('painters follow their inputs', () {
    Widget surface(
      CanvasDocument document, {
      CanvasCursors? cursors,
      Duration glide = Duration.zero,
    }) =>
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: Colors.red,
            cursors: cursors,
            cursorGlide: glide,
            onStroke: (_) {},
          ),
        );

    T? painter<T>(WidgetTester tester) => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter)
        .whereType<T>()
        .firstOrNull;

    testWidgets('client-061-A-1 a reduce-motion toggle reaches the cursors', (
      tester,
    ) async {
      final document = CanvasDocument();
      final cursors = CanvasCursors();
      await tester.pumpWidget(surface(document, cursors: cursors));
      final before = painter<CursorPainter>(tester);

      await tester.pumpWidget(
        surface(document,
            cursors: cursors, glide: const Duration(milliseconds: 80)),
      );
      expect(painter<CursorPainter>(tester), isNot(same(before)));
    });

    testWidgets('client-062-A-1 cursors that arrive later get a painter', (
      tester,
    ) async {
      final document = CanvasDocument();
      await tester.pumpWidget(surface(document));
      expect(painter<CursorPainter>(tester), isNull);

      await tester.pumpWidget(surface(document, cursors: CanvasCursors()));
      expect(painter<CursorPainter>(tester), isNotNull);
    });

    testWidgets('client-061-B-1 a new device pixel ratio rebuilds the ink', (
      tester,
    ) async {
      final document = CanvasDocument();
      Widget at(double ratio) => MediaQuery(
            data: MediaQueryData(devicePixelRatio: ratio),
            child: surface(document),
          );
      await tester.pumpWidget(at(1));
      expect(painter<StrokePainter>(tester)!.devicePixelRatio, 1);

      await tester.pumpWidget(at(2));
      expect(painter<StrokePainter>(tester)!.devicePixelRatio, 2);
    });
  });
}
