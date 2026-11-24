// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The style the next note starts with, and the colours every note is drawn in.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pen_style.dart';

/// The last style a note was given, so the next note placed takes it; kept across opens of the canvas.
final canvasLastNoteStyleProvider = StateProvider<CanvasNoteStyle>(
  (ref) => const CanvasNoteStyle(),
);

/// A note's colours in [tokens]' theme: the pen palette, the theme's own text ink, and the two fixed inks "auto" flips between on a fill the theme's ink cannot be read on.
NotePalette canvasNotePalette(AppTokens tokens) => NotePalette(
  inkColors: canvasPenInkByKey,
  textInk: tokens.textPrimary,
  boardBackground: tokens.surfaceBase,
  darkInk: AppTokens.light.textPrimary,
  lightInk: AppTokens.dark.textPrimary,
);
