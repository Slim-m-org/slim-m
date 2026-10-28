// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note paints at the text size it was stored with, and at the old default when it has none.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

double _lineHeightOf({double? fontSize}) {
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
        w: 330,
        h: 210,
        points: const [],
        width: 0,
        colorKey: 'note',
        kind: CanvasObjectKind.note,
        text: 'hello',
        fontSize: fontSize,
      ),
    )
    ..refresh();
  final canvas = RecordingCanvas();
  StrokePainter(document: document, ink: ink)
      .paint(canvas, const Size(400, 400));
  return canvas.paragraphs.single.height;
}

void main() {
  test('a note with no stored size paints at the original default', () {
    expect(_lineHeightOf(), closeTo(noteWorldFontSize * noteLineHeight, 0.5));
  });

  test('a note with a stored size paints at that size', () {
    expect(_lineHeightOf(fontSize: 24), closeTo(24 * noteLineHeight, 0.5));
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
