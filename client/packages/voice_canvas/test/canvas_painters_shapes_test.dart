// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Note and shape objects: a note's own box and text truncation, and a
/// shape's own primitive and zoom scaling.
///
/// Split out of `canvas_painters_test.dart` once that file crossed the
/// 500-line hard limit; both share `support/canvas_painter_fixtures.dart`'s
/// stub [Canvas].
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

void main() {
  test('a note draws its own box, distinct from a plain stroke', () {
    final document = CanvasDocument()..setViewport(const Size(400, 400));
    document.applyPlaced(noteAt());
    document.refresh();
    addTearDown(document.dispose);

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink).paint(
      canvas,
      const Size(400, 400),
    );

    expect(
      canvas.roundedRectCalls,
      greaterThanOrEqualTo(2),
      reason: 'a note draws a fill and a border, the same two-call shape an '
          'image placeholder already uses',
    );
  });

  test(
      'a note far too long for its box has its text truncated by its own '
      'layout, not merely painted past the box and clipped', () {
    final document = CanvasDocument()..setViewport(const Size(400, 400));
    document.applyPlaced(
      CanvasStrokeInput(
        id: 'overflow',
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: 220,
        h: 140,
        points: const [],
        width: 0,
        colorKey: 'note',
        kind: CanvasObjectKind.note,
        text: List.filled(30, 'one two three four five').join(' '),
      ),
    );
    document.refresh();
    addTearDown(document.dispose);

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink).paint(
      canvas,
      const Size(400, 400),
    );

    expect(canvas.paragraphs, hasLength(1));
    const pad = 8.0;
    expect(
      canvas.paragraphs.single.height,
      lessThanOrEqualTo(140 - pad * 2 + 0.5),
      reason: 'a fixed maxLines: 200 would lay out to its full natural '
          'height regardless of the box, and rely on the paint clip to '
          'hide the rest with no ellipsis ever appended',
    );
  });

  test('noteMaxLines: derived from the box, not a fixed constant', () {
    expect(noteMaxLines(140, 15.6), 7);
    expect(noteMaxLines(140, 15.6, pad: 8), 7);
    expect(noteMaxLines(20.6, 15.6, pad: 2), 1);
    expect(
      noteMaxLines(3, 15.6, pad: 2),
      0,
      reason: 'a box too small to show even one padded line has nothing to '
          'show',
    );
  });

  test(
      'an image placeholder rounds its corner the same as a note, not the '
      'radius step the design system retired', () {
    final noteDocument = CanvasDocument()..setViewport(const Size(400, 400));
    noteDocument.applyPlaced(noteAt());
    noteDocument.refresh();
    addTearDown(noteDocument.dispose);
    final noteCanvas = RecordingCanvas();
    StrokePainter(document: noteDocument, ink: ink).paint(
      noteCanvas,
      const Size(400, 400),
    );

    final imageDocument = documentWithImage(loadFailed: true);
    addTearDown(imageDocument.dispose);
    final imageCanvas = RecordingCanvas();
    StrokePainter(document: imageDocument, ink: ink).paint(
      imageCanvas,
      const Size(400, 400),
    );

    expect(imageCanvas.roundedRectRadii, isNotEmpty);
    expect(
      imageCanvas.roundedRectRadii.toSet(),
      noteCanvas.roundedRectRadii.toSet(),
      reason: 'two box objects on the same canvas should share one corner '
          'treatment, not a radius the design language dropped for being '
          'indistinguishable from it under a hairline',
    );
  });

  test('an elevated note or shape draws its shadow too', () {
    for (final object in [noteAt(), shapeAt(CanvasShapeKind.rectangle)]) {
      final document = CanvasDocument()..setViewport(const Size(400, 400));
      document.applyPlaced(object);
      document.elevatedObjectId.value = object.id;
      document.refresh();

      final canvas = RecordingCanvas();
      StrokePainter(
              document: document, ink: ink, elevationShadow: elevationShadow)
          .paint(canvas, const Size(400, 400));

      expect(canvas.shadowRectCalls, 1, reason: 'kind: ${object.kind}');
      document.dispose();
    }
  });

  test('each shape kind draws through its own primitive', () {
    for (final (kind, assertOn)
        in <(CanvasShapeKind, void Function(RecordingCanvas))>[
      (CanvasShapeKind.rectangle, (c) => expect(c.rectCalls, 1)),
      (
        CanvasShapeKind.ellipse,
        // A polyline, never drawOval, which Impeller's Linux GL renderer breaks.
        (c) => expect((c.ovalCalls, c.pathCalls), (0, 1)),
      ),
      (CanvasShapeKind.line, (c) => expect(c.lineCalls, 1)),
    ]) {
      final document = CanvasDocument()..setViewport(const Size(400, 400));
      document.applyPlaced(shapeAt(kind));
      document.refresh();
      final canvas = RecordingCanvas();
      StrokePainter(document: document, ink: ink).paint(
        canvas,
        const Size(400, 400),
      );
      assertOn(canvas);
      document.dispose();
    }
  });

  test('an arrow draws its line plus a two-segment head; a line does not', () {
    final line = CanvasDocument()..setViewport(const Size(400, 400));
    line.applyPlaced(shapeAt(CanvasShapeKind.line));
    line.refresh();
    final lineCanvas = RecordingCanvas();
    StrokePainter(document: line, ink: ink).paint(
      lineCanvas,
      const Size(400, 400),
    );
    expect(lineCanvas.lineCalls, 1);
    line.dispose();

    final arrow = CanvasDocument()..setViewport(const Size(400, 400));
    arrow.applyPlaced(shapeAt(CanvasShapeKind.arrow));
    arrow.refresh();
    final arrowCanvas = RecordingCanvas();
    StrokePainter(document: arrow, ink: ink).paint(
      arrowCanvas,
      const Size(400, 400),
    );
    expect(
      arrowCanvas.lineCalls,
      3,
      reason: 'the shaft plus the two head segments arrowheadWings computes',
    );
    arrow.dispose();
  });

  test(
      "a shape's outline scales with zoom the way a pen stroke's width "
      'does, since a shape someone drew is content by the same test', () {
    const zoom = 3.5;
    final document = CanvasDocument()..setViewport(const Size(400, 400));
    document.applyPlaced(shapeAt(CanvasShapeKind.rectangle));
    document.setCamera(const Camera(zoom: zoom));
    addTearDown(document.dispose);

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink).paint(
      canvas,
      const Size(400, 400),
    );

    expect(
      canvas.shapeStrokeWidths,
      [2.0 * zoom],
      reason: 'a fixed screen-space width would stay 2.0 regardless of zoom',
    );
    expect(
      canvas.shapeDeviceBounds,
      [const Rect.fromLTWH(0, 0, 100 * zoom, 60 * zoom)],
      reason: 'the on-screen box itself must land exactly where it did '
          'before, only the outline weight should change',
    );
  });

  test(
      "an arrow's head scales with zoom, matching its shaft, rather than "
      'staying a fixed screen-space flick beside a zoomed-in line', () {
    const zoom = 3.5;
    final document = CanvasDocument()..setViewport(const Size(400, 400));
    document.applyPlaced(shapeAt(CanvasShapeKind.arrow));
    document.setCamera(const Camera(zoom: zoom));
    addTearDown(document.dispose);

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink).paint(
      canvas,
      const Size(400, 400),
    );

    expect(canvas.lineDeviceLengths, hasLength(3));
    const worldHeadLength = 10.0;
    for (final wing in canvas.lineDeviceLengths.skip(1)) {
      expect(wing, closeTo(worldHeadLength * zoom, 0.01));
    }
  });

  test('arrowheadWings answers (to, to) for a zero-length arrow', () {
    const to = Offset(5, 5);
    expect(arrowheadWings(to, to), (to, to));
  });

  test('arrowheadWings points back from the tip, never past it', () {
    final (left, right) = arrowheadWings(Offset.zero, const Offset(100, 0));
    expect(left.dx, lessThan(100));
    expect(right.dx, lessThan(100));
  });
}
