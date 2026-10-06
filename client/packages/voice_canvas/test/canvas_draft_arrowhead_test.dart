// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The arrow being dragged and the arrow it becomes on release draw the same
/// head: one geometry, and the same on-screen size at any zoom.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

void main() {
  test(
      'the draft arrowhead is as long on screen as the committed one at zoom '
      '3', () {
    const zoom = 3.0;
    final document = CanvasDocument()..setViewport(const Size(400, 400));
    addTearDown(document.dispose);
    document.setCamera(const Camera(zoom: zoom));
    document.applyPlaced(shapeAt(CanvasShapeKind.arrow));
    document.refresh();
    final committed = RecordingCanvas();
    StrokePainter(document: document, ink: const Color(0xFF000000))
        .paint(committed, const Size(400, 400));

    final draft = DraftShape()..begin(Offset.zero, CanvasShapeKind.arrow);
    addTearDown(draft.dispose);
    draft.update(const Offset(200, 100));
    final drafted = RecordingCanvas();
    DraftShapePainter(
            draft: draft, document: document, color: const Color(0xFF000000))
        .paint(drafted, const Size(400, 400));

    expect(drafted.lineDeviceLengths, hasLength(3));
    expect(
      drafted.lineDeviceLengths[1],
      closeTo(committed.lineDeviceLengths[1], 1e-9),
      reason: 'the head must not jump size when the pointer lifts',
    );
  });
}
