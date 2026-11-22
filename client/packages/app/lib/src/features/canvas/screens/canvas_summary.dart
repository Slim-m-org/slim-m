// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-line readout of what a canvas holds, split out of
/// `canvas_pane_body.dart` for its line budget.
library;

import 'package:slimm_voice_canvas/voice_canvas.dart';

/// "N objects: X strokes, Y images, Z notes, W shapes, V text boxes", so a screen-reader
/// user or the panel header can tell an empty canvas from a busy one.
String canvasSummary(CanvasDocument document) {
  final counts = document.liveCountsByKind;
  final total =
      counts.strokes +
      counts.images +
      counts.notes +
      counts.shapes +
      counts.texts +
      counts.tiles;
  if (total == 0) return 'no objects';
  final tiles = counts.tiles == 0
      ? ''
      : ', ${_counted(counts.tiles, 'module tile', 'module tiles')}';
  return '${_counted(total, 'object', 'objects')}: '
      '${_counted(counts.strokes, 'stroke', 'strokes')}, '
      '${_counted(counts.images, 'image', 'images')}, '
      '${_counted(counts.notes, 'note', 'notes')}, '
      '${_counted(counts.shapes, 'shape', 'shapes')}, '
      '${_counted(counts.texts, 'text box', 'text boxes')}'
      '$tiles';
}

String _counted(int count, String one, String many) =>
    '$count ${count == 1 ? one : many}';
