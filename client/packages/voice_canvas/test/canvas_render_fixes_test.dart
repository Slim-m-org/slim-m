// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Rendering fidelity: ink near the screen edge, hairline ink, theme changes
/// to the lattice, and z-index bookkeeping for unconfirmed strokes.
library;

import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

CanvasStrokeInput _stroke({
  String id = 's',
  double x = 0,
  double y = 0,
  double width = 2,
  int zIndex = 1,
  CanvasObjectKind kind = CanvasObjectKind.stroke,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: zIndex,
      x: x,
      y: y,
      w: 10,
      h: 10,
      points: Float32List.fromList(<double>[0, 0, 10, 10]),
      width: width,
      colorKey: 'ink',
      kind: kind,
    );

void main() {
  test('thick ink whose box just left the view still paints its visible half',
      () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_stroke(x: 810, y: 100, width: 60))
      ..refresh();

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink)
        .paint(canvas, const Size(800, 600));

    expect(canvas.deviceStrokeWidths, [60]);
  });

  test('hairline ink is painted at the least visible width', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_stroke(width: 0.3))
      ..refresh();

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink)
        .paint(canvas, const Size(800, 600));

    expect(canvas.deviceStrokeWidths.single, closeTo(minInkScreenPx, 1e-9));
  });

  test('a shape outline stays visible when zoomed out', () {
    final document = CanvasDocument()
      ..setViewport(const Size(800, 600))
      ..setCamera(const Camera(zoom: 0.25));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_stroke(kind: CanvasObjectKind.shape))
      ..refresh();

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink)
        .paint(canvas, const Size(800, 600));

    expect(canvas.shapeStrokeWidths.single, closeTo(minInkScreenPx, 1e-9));
  });

  test('the lattice repaints when its colours change, not before', () {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final base = GridPainter(
      document: document,
      line: const Color(0x14000000),
      letterbox: const Color(0x0A000000),
    );
    expect(
      GridPainter(
        document: document,
        line: const Color(0x14000000),
        letterbox: const Color(0x0A000000),
      ).shouldRepaint(base),
      isFalse,
    );
    expect(
      GridPainter(
        document: document,
        line: const Color(0x14FFFFFF),
        letterbox: const Color(0x0A000000),
      ).shouldRepaint(base),
      isTrue,
    );
    expect(
      GridPainter(
        document: document,
        line: const Color(0x14000000),
      ).shouldRepaint(base),
      isTrue,
    );
  });

  test('several unconfirmed strokes leave the z range to confirmed ones', () {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document
      ..applyPlaced(_stroke(id: 'a', zIndex: 5))
      ..applyPlaced(_stroke(id: 'b', zIndex: provisionalLocalZIndex))
      ..applyPlaced(_stroke(id: 'c', zIndex: provisionalLocalZIndex + 1))
      ..applyPlaced(_stroke(id: 'd', zIndex: provisionalLocalZIndex + 2));

    expect(document.zIndexRange, (5, 5));
  });

  test('shapeSegment runs head to the corner the flips name', () {
    expect(shapeSegment(10, 4), (const Offset(0, 0), const Offset(10, 4)));
    expect(
      shapeSegment(10, 4, flipX: true),
      (const Offset(10, 0), const Offset(0, 4)),
    );
    expect(
      shapeSegment(10, 4, flipX: true, flipY: true),
      (const Offset(10, 4), const Offset(0, 0)),
    );
    expect(
      shapeSegment(10, 0, flipY: true),
      (const Offset(0, 0), const Offset(10, 0)),
      reason: 'a zero-thickness axis is a plain horizontal line',
    );
  });

  test('a flipped arrow is painted from its right end to its left', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'a',
          seq: 1,
          zIndex: 1,
          x: 100,
          y: 100,
          w: 80,
          h: 0,
          points: [],
          width: 0,
          colorKey: 'shape',
          kind: CanvasObjectKind.shape,
          shapeKind: CanvasShapeKind.arrow,
          flipX: true,
        ),
      )
      ..refresh();

    final canvas = _LineCanvas();
    StrokePainter(document: document, ink: ink)
        .paint(canvas, const Size(800, 600));

    expect(canvas.lines.first, (const Offset(80, 0), const Offset(0, 0)));
    final wings = canvas.lines.skip(1).toList();
    expect(wings, hasLength(2));
    expect(
        wings.every((w) => w.$1 == const Offset(0, 0) && w.$2.dx > 0), isTrue);
  });

  test('the shape tool remembers which way the drag ran', () {
    final draft = DraftShape()
      ..begin(const Offset(100, 100), CanvasShapeKind.arrow)
      ..update(const Offset(40, 160));
    expect(draft.flip, (x: true, y: false));
    draft.update(const Offset(40, 60));
    expect(draft.flip, (x: true, y: true));
    draft.take();
    expect(draft.flip, (x: true, y: true),
        reason: 'asked for after pointer-up');
  });
}

class _LineCanvas implements Canvas {
  final List<(Offset, Offset)> lines = [];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines.add((p1, p2));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
