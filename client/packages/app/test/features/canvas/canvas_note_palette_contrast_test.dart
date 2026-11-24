// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette every theme hands the canvas keeps a default note's text readable on its fill.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_note_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _themes = {
  'light': AppTokens.light,
  'dark': AppTokens.dark,
  'true_black': AppTokens.trueBlack,
  'mocha': AppTokens.mocha,
  'soft': AppTokens.soft,
  'forest': AppTokens.forest,
  'halloween': AppTokens.halloween,
};

double _ratio(Color a, Color b) {
  final hi = a.computeLuminance() > b.computeLuminance() ? a : b;
  final lo = identical(hi, a) ? b : a;
  return (hi.computeLuminance() + 0.05) / (lo.computeLuminance() + 0.05);
}

void main() {
  for (final MapEntry(key: name, value: tokens) in _themes.entries) {
    test('a default note reads on every fill and opacity in $name', () {
      final palette = canvasNotePalette(tokens);
      for (final fill in <String?>[null, '#ffeb3b', '#1b1e22', '#808080']) {
        for (final opacity in <double?>[null, 0, 0.25, 0.5, 0.75, 1]) {
          final style = CanvasNoteStyle(fill: fill, fillOpacity: opacity);
          final ink = palette.inkOf(style, AppCanvasColors.note);
          final behind = palette.behind(style, AppCanvasColors.note);
          expect(
            _ratio(ink, behind),
            greaterThanOrEqualTo(minNoteContrast),
            reason: '$name fill $fill opacity $opacity',
          );
        }
      }
    });
  }
}
