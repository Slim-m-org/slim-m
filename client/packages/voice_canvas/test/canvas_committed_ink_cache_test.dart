// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A frame that changes no committed content must not re-issue the committed
/// ink.
///
/// Impeller has no raster cache, so every `StrokePainter.paint` re-rasterises
/// every visible stroke. A remote cursor moving keeps frames coming, so a
/// still board pays the full cost per frame (C-014).
library;

import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

const _strokeCount = 2000;

CanvasDocument _busyBoard() {
  final document = CanvasDocument()..setViewport(const Size(1000, 1000));
  for (var i = 0; i < _strokeCount; i++) {
    document.applyPlaced(
      CanvasStrokeInput(
        id: 's$i',
        seq: i + 1,
        zIndex: i,
        x: (i % 50) * 18.0,
        y: (i ~/ 50) * 18.0,
        w: 16,
        h: 16,
        points: Float32List.fromList(<double>[0, 0, 16, 16]),
        width: 2,
        colorKey: 'ink',
      ),
    );
  }
  document.setCamera(const Camera(x: 1, y: 1));
  return document;
}

void main() {
  test('a repaint with unchanged content re-issues no committed strokes', () {
    final document = _busyBoard();
    addTearDown(document.dispose);
    final painter = StrokePainter(document: document, ink: ink);

    final first = RecordingCanvas();
    painter.paint(first, const Size(1000, 1000));
    expect(
      first.deviceStrokeWidths.length,
      greaterThan(1000),
      reason: 'the fixture must put a busy board in view or the test proves '
          'nothing',
    );

    final second = RecordingCanvas();
    painter.paint(second, const Size(1000, 1000));

    expect(
      second.deviceStrokeWidths.length,
      lessThan(first.deviceStrokeWidths.length ~/ 10),
      reason: 'nothing committed changed, yet the painter re-drew '
          '${second.deviceStrokeWidths.length} strokes; Impeller re-rasterises '
          'each one every frame, so a cursor move alone costs the whole board',
    );
  });
}
