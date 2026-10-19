// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/selection_painter.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_painter_fixtures.dart';

void main() {
  /// The side of the corner handles drawn for a selected note at [zoom].
  double handleSide({required bool touch, required double zoom}) {
    final document = CanvasDocument()
      ..setViewport(const Size(800, 600))
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'n',
          seq: 1,
          zIndex: 1,
          x: 100,
          y: 100,
          w: 200,
          h: 120,
          points: [],
          width: 0,
          colorKey: 'amber',
          kind: CanvasObjectKind.note,
          text: 'hi',
        ),
      )
      ..refresh()
      ..setCamera(Camera(zoom: zoom))
      ..selectedObjectId.value = 'n';
    addTearDown(document.dispose);
    final canvas = RecordingCanvas();
    SelectionPainter(
      document: document,
      outline: const Color(0xFF0000FF),
      handleFill: const Color(0xFFFFFFFF),
      handleBorder: const Color(0xFF0000FF),
      touchHandles: touch,
    ).paint(canvas, const Size(800, 600));
    return canvas.shapeDeviceBounds.skip(1).first.width;
  }

  test('touch handles are larger than mouse handles', () {
    expect(
      handleSide(touch: true, zoom: 1),
      greaterThan(handleSide(touch: false, zoom: 1)),
    );
    expect(handleSide(touch: true, zoom: 1), touchResizeHandleVisualSize);
  });

  test('a handle keeps its screen size at any zoom', () {
    for (final touch in [true, false]) {
      final sizes = {
        for (final zoom in [0.25, 1.0, 3.0])
          handleSide(touch: touch, zoom: zoom),
      };
      expect(sizes.length, 1, reason: 'touch=$touch');
    }
  });
}
