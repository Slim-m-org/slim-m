// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CursorPainter]: the glyph's contrast rim, and the label chip reading the
/// caller's own type family rather than Flutter's platform default.
///
/// A design review found both missing: the glyph's "white" pass painted the
/// exact same path with no stroke and no inset, so the second, identical fill
/// covered it completely and no rim ever showed; and the label's `TextStyle`
/// carried no `fontFamily` at all, so a cursor was the one piece of text on
/// the canvas not drawn in the product's own IBM Plex Sans.
library;

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Records every `drawPath` call's [Paint] and every `drawRRect` call's
/// width, the same "record what the painter actually reached" technique
/// `canvas_painters_test.dart` already uses for [StrokePainter].
class _RecordingCanvas implements Canvas {
  final List<Paint> pathPaints = <Paint>[];
  final List<double> rrectWidths = <double>[];
  final List<Rect> rrectBounds = <Rect>[];

  @override
  void drawPath(Path path, Paint paint) => pathPaints.add(paint);

  @override
  void drawRRect(RRect rrect, Paint paint) {
    rrectWidths.add(rrect.width);
    rrectBounds.add(rrect.outerRect);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

CanvasCursors _oneCursor({String label = 'Ada Lovelace'}) {
  final cursors = CanvasCursors();
  cursors.upsert(id: 'user-ada', x: 0, y: 0, label: label, colorIndex: 0);
  return cursors;
}

Future<void> _loadPlexSans() async {
  final loader = FontLoader('IBM Plex Sans')
    ..addFont(
      File('../design_system/fonts/IBMPlexSans-Regular.ttf')
          .readAsBytes()
          .then(ByteData.sublistView),
    );
  await loader.load();
}

void main() {
  setUpAll(_loadPlexSans);

  test('the glyph draws a visible stroke rim, not a second identical fill', () {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final cursors = _oneCursor();
    addTearDown(cursors.dispose);

    final canvas = _RecordingCanvas();
    CursorPainter(
        cursors: cursors,
        document: document,
        colors: const [Color(0xFFE0699A)]).paint(canvas, const Size(400, 400));

    expect(
      canvas.pathPaints.length,
      2,
      reason: 'one glyph is exactly two drawPath calls: the rim, then the fill',
    );
    expect(
      canvas.pathPaints[0].style,
      PaintingStyle.stroke,
      reason: 'the first pass must be a stroke or it paints over, not around, '
          'the second - invisible either way a fill could hide it',
    );
    expect(
      canvas.pathPaints[0].strokeWidth,
      greaterThan(0),
      reason: 'a zero-width stroke draws nothing, the same as no rim at all',
    );
    expect(canvas.pathPaints[1].style, PaintingStyle.fill);
  });

  test(
      'the label chip is sized from the caller\'s font family, not the '
      'platform default', () {
    final document = CanvasDocument();
    addTearDown(document.dispose);

    final withoutFamily = _oneCursor();
    addTearDown(withoutFamily.dispose);
    final defaultFont = _RecordingCanvas();
    CursorPainter(
      cursors: withoutFamily,
      document: document,
      colors: const [Color(0xFFE0699A)],
    ).paint(defaultFont, const Size(400, 400));

    final withFamily = _oneCursor();
    addTearDown(withFamily.dispose);
    final plexSans = _RecordingCanvas();
    CursorPainter(
      cursors: withFamily,
      document: document,
      colors: const [Color(0xFFE0699A)],
      labelFontFamily: 'IBM Plex Sans',
    ).paint(plexSans, const Size(400, 400));

    // The only drawRRect call either painter makes is the label chip.
    expect(
      plexSans.rrectWidths.last,
      isNot(defaultFont.rrectWidths.last),
      reason: 'a real font family measures glyphs differently from '
          "Flutter's test placeholder face; identical widths means the "
          'family was never actually reaching the TextStyle',
    );
  });

  test('a chip near the right edge flips inside the surface', () {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final cursors = CanvasCursors()
      ..upsert(id: 'u', x: 380, y: 100, label: 'Ada Lovelace', colorIndex: 0);
    addTearDown(cursors.dispose);

    final canvas = _RecordingCanvas();
    CursorPainter(
        cursors: cursors,
        document: document,
        colors: const [Color(0xFFE0699A)]).paint(canvas, const Size(400, 400));

    final chip = canvas.rrectBounds.single;
    expect(chip.right, lessThanOrEqualTo(400));
    expect(chip.left, lessThan(380), reason: 'it sits left of the pointer');
  });

  test('a long name stays one line', () {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final cursors = _oneCursor(label: 'A very long display name ' * 8);
    addTearDown(cursors.dispose);

    final canvas = _RecordingCanvas();
    CursorPainter(
        cursors: cursors,
        document: document,
        colors: const [Color(0xFFE0699A)]).paint(canvas, const Size(400, 400));

    expect(canvas.rrectBounds.single.height, lessThan(24));
  });
}
