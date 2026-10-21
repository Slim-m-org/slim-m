// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _shape(CanvasShapeKind kind, {int zIndex = 2}) =>
    CanvasStrokeInput(
      id: 'frame',
      seq: zIndex,
      zIndex: zIndex,
      x: 0,
      y: 0,
      w: 400,
      h: 400,
      points: const [],
      width: 2,
      colorKey: 'shape',
      kind: CanvasObjectKind.shape,
      shapeKind: kind,
    );

void main() {
  test('the empty interior of a rectangle frame is not a hit', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(_shape(CanvasShapeKind.rectangle))
      ..refresh();

    expect(hitTestBoxAt(document, const Offset(200, 200)), isNull);
  });

  test('a note inside a rectangle frame stays reachable under the frame', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'note',
          seq: 1,
          zIndex: 1,
          x: 180,
          y: 180,
          w: 40,
          h: 40,
          points: [],
          width: 0,
          colorKey: 'note',
          kind: CanvasObjectKind.note,
          text: 'hi',
        ),
      )
      ..applyPlaced(_shape(CanvasShapeKind.rectangle))
      ..refresh();

    expect(hitTestBoxAt(document, const Offset(200, 200)), 'note');
  });
}
