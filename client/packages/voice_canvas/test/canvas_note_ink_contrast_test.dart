// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note or text box with no text colour of its own draws text that reads on what is behind it, in every theme.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'visual/visual_tokens.dart';

const _themes = [
  VisualTheme.light,
  VisualTheme.dark,
  VisualTheme.trueBlack,
  VisualTheme.mocha,
  VisualTheme.soft,
  VisualTheme.forest,
  VisualTheme.halloween,
];
const _amber = Color(0xFFE8B04B);
const _size = Size(320, 200);

CanvasStrokeInput _object(CanvasObjectKind kind, CanvasNoteStyle style) =>
    CanvasStrokeInput(
      id: 'o',
      seq: 1,
      zIndex: 1,
      x: 10,
      y: 10,
      w: 300,
      h: 180,
      points: const [],
      width: 0,
      colorKey: kind == CanvasObjectKind.text ? 'ink' : 'note',
      kind: kind,
      text: 'WWW WWW',
      noteStyle: style,
    );

NotePalette _paletteOf(VisualTheme theme) => NotePalette(
      textInk: theme.textPrimary,
      boardBackground: theme.surfaceBase,
    );

Future<ByteData> _render(
  WidgetTester tester,
  VisualTheme theme,
  CanvasStrokeInput object,
) async {
  final document = CanvasDocument()
    ..setViewport(_size)
    ..applyPlaced(object)
    ..refresh();
  addTearDown(document.dispose);
  final painter = StrokePainter(
    document: document,
    ink: _amber,
    noteColor: _amber,
    notePalette: _paletteOf(theme),
  );
  addTearDown(painter.dispose);
  late ByteData data;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(Offset.zero & _size, Paint()..color = theme.surfaceBase);
    painter.paint(canvas, _size);
    final image = await recorder.endRecording().toImage(320, 200);
    data = (await image.toByteData())!;
  });
  return data;
}

Color _pixel(ByteData data, int x, int y) {
  final i = (y * 320 + x) * 4;
  return Color.fromARGB(
    255,
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
  );
}

double _ratio(Color a, Color b) {
  final hi = math.max(a.computeLuminance(), b.computeLuminance());
  final lo = math.min(a.computeLuminance(), b.computeLuminance());
  return (hi + 0.05) / (lo + 0.05);
}

/// The contrast of the glyph pixel that stands furthest from the box's own background.
double _textContrast(ByteData data) {
  final background = _pixel(data, 14, 186);
  var best = 1.0;
  for (var y = 14; y < 120; y++) {
    for (var x = 14; x < 306; x++) {
      best = math.max(best, _ratio(_pixel(data, x, y), background));
    }
  }
  return best;
}

void main() {
  for (final theme in _themes) {
    for (final fill in <String?>[null, '#ffeb3b', '#1b1e22']) {
      for (final opacity in <double?>[null, 0, 0.5, 1]) {
        testWidgets(
            'a default note reads on its fill: ${theme.name} fill $fill opacity $opacity',
            (tester) async {
          final data = await _render(
            tester,
            theme,
            _object(
              CanvasObjectKind.note,
              CanvasNoteStyle(fill: fill, fillOpacity: opacity),
            ),
          );
          expect(_textContrast(data), greaterThanOrEqualTo(minNoteContrast));
        });
      }
    }
    testWidgets('a default text box reads on the board: ${theme.name}',
        (tester) async {
      final data = await _render(
        tester,
        theme,
        _object(CanvasObjectKind.text, const CanvasNoteStyle()),
      );
      expect(_textContrast(data), greaterThanOrEqualTo(minNoteContrast));
    });
  }

  test(
      'a default note keeps the theme text colour the board drew before notes had styles',
      () {
    for (final theme in _themes) {
      expect(
        _paletteOf(theme).inkOf(const CanvasNoteStyle(), _amber),
        theme.textPrimary,
        reason: theme.name,
      );
    }
  });
}
