// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shape is hit on its drawn outline, whatever its kind, and the topmost
/// object of any kind wins in a single pass.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _shape(String id, CanvasShapeKind kind, {int z = 1}) =>
    CanvasStrokeInput(
      id: id,
      seq: z,
      zIndex: z,
      x: 100,
      y: 100,
      w: 200,
      h: 100,
      points: const [],
      width: 2,
      colorKey: 'shape',
      kind: CanvasObjectKind.shape,
      shapeKind: kind,
    );

CanvasDocument _with(List<CanvasStrokeInput> inputs) {
  final document = CanvasDocument()..setViewport(const Size(800, 600));
  inputs.forEach(document.applyPlaced);
  return document..refresh();
}

void main() {
  test(
      'an ellipse is hit on its curve, not at its centre or its bounding corner',
      () {
    final document = _with([_shape('e', CanvasShapeKind.ellipse)]);

    expect(hitTestBoxAt(document, const Offset(300, 150)), 'e');
    expect(hitTestBoxAt(document, const Offset(200, 100)), 'e');
    expect(hitTestBoxAt(document, const Offset(200, 150)), isNull);
    expect(hitTestBoxAt(document, const Offset(104, 104)), isNull);
  });

  test('a line is hit along its diagonal and nowhere else in its box', () {
    final document = _with([_shape('l', CanvasShapeKind.line)]);

    expect(hitTestBoxAt(document, const Offset(200, 150)), 'l');
    expect(hitTestBoxAt(document, const Offset(290, 100)), isNull);
  });

  test('a rectangle is hit on any of its four sides', () {
    final document = _with([_shape('r', CanvasShapeKind.rectangle)]);

    for (final edge in const [
      Offset(100, 150),
      Offset(300, 150),
      Offset(200, 100),
      Offset(200, 200),
    ]) {
      expect(hitTestBoxAt(document, edge), 'r', reason: '$edge');
    }
    expect(hitTestBoxAt(document, const Offset(200, 150)), isNull);
  });

  test('a finger reaches further from the outline than a mouse', () {
    final document = _with([_shape('r', CanvasShapeKind.rectangle)]);
    const near = Offset(90, 150);

    expect(hitTestTopmost(document, near), isNull);
    expect(hitTestTopmost(document, near, touch: true), 'r');
  });

  test('one pass answers with whatever is on top, ink over a frame', () {
    final document = _with([
      _shape('frame', CanvasShapeKind.rectangle),
      const CanvasStrokeInput(
        id: 'ink',
        seq: 2,
        zIndex: 2,
        x: 100,
        y: 100,
        w: 100,
        h: 0,
        points: [0, 0, 100, 0],
        width: 3,
        colorKey: 'annotation',
      ),
    ]);

    expect(hitTestTopmost(document, const Offset(150, 100)), 'ink');
    expect(hitTestTopmost(document, const Offset(250, 100)), 'frame');
  });

  test('a kind filter skips what it does not accept', () {
    final document = _with([_shape('frame', CanvasShapeKind.rectangle)]);

    expect(
      hitTestTopmost(
        document,
        const Offset(100, 150),
        accepts: (stroke) => stroke.kind == CanvasObjectKind.stroke,
      ),
      isNull,
    );
  });

  test('nothing past the board edge can be hit', () {
    final document = _with([_shape('r', CanvasShapeKind.rectangle)])
      ..setBoard(const Rect.fromLTWH(150, 0, 500, 600));

    expect(hitTestTopmost(document, const Offset(100, 150)), isNull);
  });
}
