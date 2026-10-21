// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A moved stroke must paint where its box and hit test say it is.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

void main() {
  test('a moved stroke paints at its new box, not at twice the offset', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'a',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 10,
          h: 5,
          points: [0, 0, 10, 5],
          width: 3,
          colorKey: 'annotation',
        ),
      )
      ..moveObject('a', 100, 100, 10, 5)
      ..refresh();

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink)
        .paint(canvas, const Size(800, 600));

    expect(canvas.deviceBounds, [const Rect.fromLTRB(100, 100, 110, 105)]);
  });
}
