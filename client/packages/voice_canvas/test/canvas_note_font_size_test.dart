// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note's text scales with its box: the reference box paints at the reference size, and a resize scales it.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

double _lineHeightOf({double w = 330, double h = 210}) {
  final document = CanvasDocument()..setViewport(const Size(400, 400));
  addTearDown(document.dispose);
  document
    ..applyPlaced(
      CanvasStrokeInput(
        id: 'n',
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: w,
        h: h,
        points: const [],
        width: 0,
        colorKey: 'note',
        kind: CanvasObjectKind.note,
        text: 'hello',
      ),
    )
    ..refresh();
  final canvas = RecordingCanvas();
  StrokePainter(document: document, ink: ink)
      .paint(canvas, const Size(400, 400));
  return canvas.paragraphs.single.height;
}

void main() {
  test('a note in the reference box paints at the reference size', () {
    expect(
      _lineHeightOf(),
      closeTo(noteReferenceFontSize * noteLineHeight, 0.5),
    );
  });

  test('a note twice as large paints its text twice as large', () {
    expect(
      _lineHeightOf(w: 660, h: 420),
      closeTo(noteReferenceFontSize * 2 * noteLineHeight, 0.5),
    );
  });

  test('a note stretched in one direction only grows with its smaller side',
      () {
    expect(
      _lineHeightOf(w: 660, h: 210),
      closeTo(noteReferenceFontSize * noteLineHeight, 0.5),
    );
  });

  test('the document hands a note its stored size back for an edit to keep',
      () {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 'n',
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: 100,
        h: 100,
        points: [],
        width: 0,
        colorKey: 'note',
        kind: CanvasObjectKind.note,
        text: 'hi',
        fontSize: 18,
      ),
    );
    expect(document.noteFontSizeOf('n'), 18);
    expect(document.noteFontSizeOf('missing'), isNull);
  });
}
