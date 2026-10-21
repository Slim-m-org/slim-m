// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput horizontalStroke(
  String id, {
  double y = 0,
  int zIndex = 0,
  double width = 3,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: zIndex,
      zIndex: zIndex,
      x: 0,
      y: y,
      w: 100,
      h: 0,
      points: const [0, 0, 100, 0],
      width: width,
      colorKey: 'annotation',
    );

CanvasStrokeInput imageAt(
  String id, {
  double x = 0,
  double y = 0,
  double w = 50,
  double h = 50,
  int zIndex = 0,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: zIndex,
      zIndex: zIndex,
      x: x,
      y: y,
      w: w,
      h: h,
      points: const [],
      width: 0,
      colorKey: '',
      kind: CanvasObjectKind.image,
      attachmentId: 'sha-$id',
    );

void main() {
  test('a point on the line is a hit', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('a'))
      ..refresh();

    expect(hitTestStroke(document, const Offset(50, 0)), 'a');
  });

  test('a point well past the tolerance is not a hit', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('a', width: 2))
      ..refresh();

    expect(hitTestStroke(document, const Offset(50, 40), slopPx: 4), isNull);
  });

  test('a point just inside width/2 + slop is a hit, just outside is not', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('a', width: 2))
      ..refresh();

    // tolerance = width / 2 + slop = 1 + 4 = 5.
    expect(hitTestStroke(document, const Offset(50, 4.9), slopPx: 4), 'a');
    expect(hitTestStroke(document, const Offset(50, 5.1), slopPx: 4), isNull);
  });

  test('the topmost stroke wins when two overlap', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('under', zIndex: 1))
      ..applyPlaced(horizontalStroke('over', zIndex: 2))
      ..refresh();

    expect(hitTestStroke(document, const Offset(50, 0)), 'over');
  });

  test('a removed stroke is never hit', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('a'))
      ..refresh();
    expect(hitTestStroke(document, const Offset(50, 0)), 'a');

    document
      ..removeObject('a')
      ..refresh();
    expect(hitTestStroke(document, const Offset(50, 0)), isNull);
  });

  test('a killed (never-landed) stroke is never hit', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('a'))
      ..refresh();
    expect(hitTestStroke(document, const Offset(50, 0)), 'a');

    document
      ..kill('a')
      ..refresh();
    expect(hitTestStroke(document, const Offset(50, 0)), isNull);
  });

  test('allowed skips a disallowed candidate for the one behind it', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('foreign', zIndex: 2))
      ..applyPlaced(horizontalStroke('mine', zIndex: 1))
      ..refresh();

    expect(hitTestStroke(document, const Offset(50, 0)), 'foreign');
    expect(
      hitTestStroke(
        document,
        const Offset(50, 0),
        allowed: (stroke) => stroke.id == 'mine',
      ),
      'mine',
    );
  });

  test('allowed refusing every candidate is a miss, not the nearest one', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('a'))
      ..refresh();

    expect(
      hitTestStroke(document, const Offset(50, 0), allowed: (_) => false),
      isNull,
    );
  });

  test('a single-point stroke is hit by proximity to that point', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'dot',
          seq: 1,
          zIndex: 1,
          x: 10,
          y: 10,
          w: 0,
          h: 0,
          points: [0, 0],
          width: 2,
          colorKey: 'annotation',
        ),
      )
      ..refresh();

    expect(hitTestStroke(document, const Offset(11, 11)), 'dot');
    expect(hitTestStroke(document, const Offset(200, 200)), isNull);
  });

  test('a point inside an image box is a hit, outside is not', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(imageAt('pic', x: 10, y: 10, w: 50, h: 50))
      ..refresh();

    expect(hitTestBoxAt(document, const Offset(20, 20)), 'pic');
    expect(hitTestBoxAt(document, const Offset(200, 200)), isNull);
  });

  test('hitTestBoxAt never matches a stroke sharing the same point', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('line'))
      ..refresh();

    expect(hitTestBoxAt(document, const Offset(50, 0)), isNull);
  });

  test('the topmost image wins when two overlap', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(imageAt('under', x: 0, y: 0, w: 50, h: 50, zIndex: 1))
      ..applyPlaced(imageAt('over', x: 0, y: 0, w: 50, h: 50, zIndex: 2))
      ..refresh();

    expect(hitTestBoxAt(document, const Offset(10, 10)), 'over');
  });

  test('a point inside a note box, or on the outline of a shape, is a hit', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'note',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 40,
          h: 40,
          points: [],
          width: 0,
          colorKey: 'note',
          kind: CanvasObjectKind.note,
          text: 'hi',
        ),
      )
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'shape',
          seq: 2,
          zIndex: 2,
          x: 100,
          y: 100,
          w: 40,
          h: 40,
          points: [],
          width: 0,
          colorKey: 'shape',
          kind: CanvasObjectKind.shape,
          shapeKind: CanvasShapeKind.rectangle,
        ),
      )
      ..refresh();

    expect(hitTestBoxAt(document, const Offset(10, 10)), 'note');
    expect(hitTestBoxAt(document, const Offset(100.2, 120)), 'shape');
  });

  test('allowed skips a disallowed image for the one behind it', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(imageAt('foreign', x: 0, y: 0, w: 50, h: 50, zIndex: 2))
      ..applyPlaced(imageAt('mine', x: 0, y: 0, w: 50, h: 50, zIndex: 1))
      ..refresh();

    expect(
      hitTestBoxAt(
        document,
        const Offset(10, 10),
        allowed: (stroke) => stroke.id == 'mine',
      ),
      'mine',
    );
  });

  test('the hit reach is the same on screen at any zoom', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(horizontalStroke('a', width: 0))
      ..refresh()
      ..setCamera(const Camera(zoom: 0.25));

    // 12 screen px at 0.25 zoom is 48 world units.
    expect(
      hitTestStroke(document, const Offset(50, 47), slopPx: touchHitSlopPx),
      'a',
    );
    expect(
      hitTestStroke(document, const Offset(50, 49), slopPx: touchHitSlopPx),
      isNull,
    );
  });

  test('a touch slop reaches a box just outside its edge', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(imageAt('img', x: 100, y: 100))
      ..refresh();

    expect(hitTestBoxAt(document, const Offset(95, 120)), isNull);
    expect(
      hitTestBoxAt(document, const Offset(95, 120), slopPx: touchHitSlopPx),
      'img',
    );
  });
}
