// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note's body text is laid out once and reused across camera moves; a pan reuses the layout, a zoom or resize rebuilds it.
/// Counts layouts through [debugNoteLabelLayoutCounts], since a rendered frame looks identical either way.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';
import 'package:slimm_voice_canvas/src/note_label_cache.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class _RecordingCanvas implements Canvas {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

CanvasStrokeInput _note(String id, {double w = 220, double h = 140}) =>
    CanvasStrokeInput(
      id: id,
      seq: 0,
      zIndex: 0,
      x: 0,
      y: 0,
      w: w,
      h: h,
      points: const [],
      width: 0,
      colorKey: 'annotation',
      kind: CanvasObjectKind.note,
      text: 'a sticky note with enough words to wrap across a few lines',
    );

StrokePainter _painter(CanvasDocument document) =>
    StrokePainter(document: document, ink: const Color(0xFF1A1A1A));

void main() {
  test('a continuous zoom gesture does not re-lay-out a note every frame', () {
    debugResetNoteLabelLayoutCounts();
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_note('n1'))
      ..refresh();

    final painter = _painter(document);
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(800, 600));
    const frames = 30;
    for (var i = 1; i <= frames; i++) {
      document.setCamera(Camera(zoom: 1 + i * 0.01));
      painter.paint(canvas, const Size(800, 600));
    }
    expect(
      document.camera.zoom,
      greaterThan(1.2),
      reason: 'the zoom must actually move or the test is vacuous',
    );
    expect(
      debugNoteLabelLayoutCounts['n1'],
      lessThan(frames ~/ 3),
      reason: 'the layout key holds the exact zoom, so every zoom '
          'frame re-shapes every visible note',
    );
  });
}
