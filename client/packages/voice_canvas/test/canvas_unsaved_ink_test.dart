// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ink whose save is being retried paints faded, and the count the pane's hint reads follows it.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

CanvasDocument _documentWithStroke() {
  final document = CanvasDocument()..setViewport(const Size(800, 600));
  addTearDown(document.dispose);
  document
    ..applyPlaced(
      const CanvasStrokeInput(
        id: 'a',
        seq: 0,
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
    ..refresh();
  return document;
}

List<Color> _paintedColors(CanvasDocument document) {
  final canvas = RecordingCanvas();
  StrokePainter(document: document, ink: ink)
      .paint(canvas, const Size(800, 600));
  return canvas.pathColors;
}

void main() {
  test('a stroke waiting on a retry paints faded, then solid once saved', () {
    final document = _documentWithStroke();
    expect(_paintedColors(document).single.a, ink.a);

    document.setUnsaved('a', unsaved: true);
    final faded = _paintedColors(document).single;
    expect(faded.a, lessThan(ink.a));
    expect(faded.a, greaterThan(0));
    expect(document.unsavedInk.count.value, 1);

    document.setUnsaved('a', unsaved: false);
    expect(_paintedColors(document).single.a, ink.a);
    expect(document.unsavedInk.count.value, 0);
  });

  test('a stroke that never landed stops counting as unsaved', () {
    final document = _documentWithStroke();
    document.setUnsaved('a', unsaved: true);
    document.kill('a');
    expect(document.unsavedInk.count.value, 0);
  });
}
