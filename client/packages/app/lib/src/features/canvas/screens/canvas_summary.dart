// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-line readout of what a canvas holds, split out of
/// `canvas_pane_body.dart` for its line budget.
library;

import 'package:slimm_voice_canvas/voice_canvas.dart';

/// "N objects: X strokes, Y images, Z notes, W shapes", so a screen-reader
/// user or the panel header can tell an empty canvas from a busy one.
String canvasSummary(CanvasDocument document) {
  final counts = document.liveCountsByKind;
  final total = counts.strokes + counts.images + counts.notes + counts.shapes;
  if (total == 0) return 'no objects';
  return '$total ${total == 1 ? 'object' : 'objects'}: '
      '${counts.strokes} ${counts.strokes == 1 ? 'stroke' : 'strokes'}, '
      '${counts.images} ${counts.images == 1 ? 'image' : 'images'}, '
      '${counts.notes} ${counts.notes == 1 ? 'note' : 'notes'}, '
      '${counts.shapes} ${counts.shapes == 1 ? 'shape' : 'shapes'}';
}
