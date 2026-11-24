// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note's style: what is read from its props, what a palette makes of it, and what the painter draws.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_painter_fixtures.dart';

const _amber = Color(0xFFE8B04B);
const _palette = NotePalette(
  inkColors: {'amber': _amber, 'blue': Color(0xFF5B8FD6)},
  textInk: Color(0xFFECEDEF),
  boardBackground: Color(0xFF17191C),
  darkInk: Color(0xFF1B1E22),
  lightInk: Color(0xFFECEDEF),
);

CanvasStrokeInput _note({CanvasNoteStyle style = const CanvasNoteStyle()}) =>
    CanvasStrokeInput(
      id: 'n',
      seq: 1,
      zIndex: 1,
      x: 0,
      y: 0,
      w: 100,
      h: 80,
      points: const [],
      width: 0,
      colorKey: 'note',
      kind: CanvasObjectKind.note,
      text: '',
      noteStyle: style,
    );

/// The colours a note is drawn with: its fill (absent when none is drawn), then its outline.
List<int> _drawn(CanvasNoteStyle style) {
  final document = CanvasDocument()
    ..setViewport(const Size(120, 100))
    ..applyPlaced(_note(style: style))
    ..refresh();
  addTearDown(document.dispose);
  final painter = StrokePainter(
    document: document,
    ink: _amber,
    noteColor: _amber,
    inkColors: _palette.inkColors,
    notePalette: _palette,
  );
  addTearDown(painter.dispose);
  final canvas = RecordingCanvas();
  painter.paint(canvas, const Size(120, 100));
  return [for (final c in canvas.roundedRectColors) c.toARGB32()];
}

void main() {
  group('reading props', () {
    test('every key is optional and a legacy note reads as the default', () {
      expect(
          CanvasNoteStyle.fromWire(const {'text': 'a', 'font_size': 14.0})
              .isDefault,
          isTrue);
    });

    test('a wrong type is ignored and an opacity is clamped', () {
      final style = CanvasNoteStyle.fromWire(const {
        'fill': 3,
        'fill_opacity': 7,
        'color': '',
        'size': 'huge',
      });
      expect(style.fill, isNull);
      expect(style.fillOpacity, 1);
      expect(style.color, isNull);
      expect(style.size, isNull);
    });

    test('toWire names every key, null for the default', () {
      expect(const CanvasNoteStyle(fill: 'blue').toWire(), {
        'fill': 'blue',
        'fill_opacity': null,
        'color': null,
        'size': null,
      });
    });

    test('the size steps scale from the text box sizes', () {
      expect(canvasNoteSizeScale(null), 1);
      expect(canvasNoteSizeScale('small'), closeTo(0.7, 1e-9));
      expect(canvasNoteSizeScale('large'), closeTo(1.2, 1e-9));
    });
  });

  group('automatic text colour', () {
    test('the theme ink stays while it reads on the fill', () {
      expect(_palette.inkOf(const CanvasNoteStyle(), _amber), _palette.textInk);
    });

    test('solid amber over the dark theme flips the text dark', () {
      const solid = CanvasNoteStyle(fillOpacity: canvasNoteSolidOpacity);
      expect(_palette.inkOf(solid, _amber), _palette.darkInk);
    });

    test('a named colour is kept whatever the fill', () {
      const style = CanvasNoteStyle(fillOpacity: 1, color: 'blue');
      expect(_palette.inkOf(style, _amber), const Color(0xFF5B8FD6));
    });
  });

  group('painting', () {
    test('a legacy note is tinted and outlined in the note colour', () {
      final colors = _drawn(const CanvasNoteStyle());
      expect(colors, hasLength(2));
      expect(Color(colors.first).a, closeTo(canvasNoteTintedOpacity, 0.01));
      expect(colors.last, _amber.toARGB32());
    });

    test('a solid note covers what is under it', () {
      final colors = _drawn(const CanvasNoteStyle(fillOpacity: 1));
      expect(colors.first, _amber.toARGB32());
    });

    test('a clear note paints only its outline', () {
      final colors = _drawn(const CanvasNoteStyle(fillOpacity: 0));
      expect(colors, [_amber.toARGB32()]);
    });

    test('a named fill colours the fill and the outline', () {
      final colors =
          _drawn(const CanvasNoteStyle(fill: 'blue', fillOpacity: 1));
      expect(colors, everyElement(0xFF5B8FD6));
    });
  });
}
