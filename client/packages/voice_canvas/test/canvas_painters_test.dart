// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The draft stroke under the pointer must paint at the width and place it
/// will keep once committed, or a stroke visibly changes size at pointer-up,
/// plus the image placeholder and its elevation shadow.
///
/// Note and shape objects have their own file, `canvas_painters_shapes_test
/// .dart`, split out once this one crossed the 500-line hard limit; both
/// share `support/canvas_painter_fixtures.dart`'s stub [Canvas].
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

void main() {
  pathColorTests();

  test(
      'a draft stroke reaches the same on-screen width as the committed '
      'stroke once zoom is not 1', () {
    const zoom = 3.5;
    final document = documentWithCommittedStroke(zoom);
    addTearDown(document.dispose);

    final committedCanvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink)
        .paint(committedCanvas, const Size(400, 400));

    final draft = draftAlongTheSameLine();
    addTearDown(draft.dispose);
    final draftCanvas = RecordingCanvas();
    DraftPainter(draft: draft, document: document, ink: ink, width: 4 * zoom)
        .paint(draftCanvas, const Size(400, 400));

    expect(committedCanvas.deviceStrokeWidths, [4.0 * zoom]);
    expect(
      draftCanvas.deviceStrokeWidths,
      committedCanvas.deviceStrokeWidths,
      reason: 'the preview must land at the width the committed stroke will '
          'have, or the stroke changes size the instant the pointer lifts',
    );
  });

  test(
      'a draft stroke lands at the same on-screen place and shape as the '
      'committed stroke', () {
    final document = documentWithCommittedStroke(3.5);
    addTearDown(document.dispose);

    final committedCanvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink)
        .paint(committedCanvas, const Size(400, 400));

    final draft = draftAlongTheSameLine();
    addTearDown(draft.dispose);
    final draftCanvas = RecordingCanvas();
    DraftPainter(draft: draft, document: document, ink: ink, width: 4)
        .paint(draftCanvas, const Size(400, 400));

    expect(draftCanvas.deviceBounds, committedCanvas.deviceBounds);
  });

  test('a load that failed for good draws the placeholder, not silence', () {
    final document = documentWithImage(loadFailed: true);
    addTearDown(document.dispose);

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink).paint(
      canvas,
      const Size(400, 400),
    );

    expect(
      canvas.roundedRectCalls,
      greaterThan(0),
      reason: 'a missing image must draw something, never nothing at all',
    );
  });

  test('a decode still in flight draws nothing yet, not the placeholder', () {
    final document = documentWithImage(loadFailed: false);
    addTearDown(document.dispose);

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink).paint(
      canvas,
      const Size(400, 400),
    );

    expect(
      canvas.roundedRectCalls,
      0,
      reason: 'the object reappears the moment its own decode lands; '
          'painting a placeholder meanwhile would flash it needlessly',
    );
  });

  test('the elevated image draws its shadow, and an idle one draws none', () {
    final document = documentWithImage(loadFailed: true)
      ..elevatedObjectId.value = 'pic';
    addTearDown(document.dispose);

    final canvas = RecordingCanvas();
    StrokePainter(
            document: document, ink: ink, elevationShadow: elevationShadow)
        .paint(canvas, const Size(400, 400));

    expect(
      canvas.shadowRectCalls,
      1,
      reason: 'only the object elevatedObjectId names earns a shadow',
    );
  });

  test('nothing draws a shadow while no object is elevated', () {
    final document = documentWithImage(loadFailed: true);
    addTearDown(document.dispose);

    final canvas = RecordingCanvas();
    StrokePainter(
            document: document, ink: ink, elevationShadow: elevationShadow)
        .paint(canvas, const Size(400, 400));

    expect(canvas.shadowRectCalls, 0);
  });

  test('an elevated image draws no shadow when none was wired in', () {
    final document = documentWithImage(loadFailed: true)
      ..elevatedObjectId.value = 'pic';
    addTearDown(document.dispose);

    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink).paint(
      canvas,
      const Size(400, 400),
    );

    expect(
      canvas.shadowRectCalls,
      0,
      reason: 'the default elevationShadow is empty, the same '
          '"pay nothing for it unwired" choice selectionOutline makes',
    );
  });

  test('a draft holding one point paints a dot at the pen screen width', () {
    final document = documentWithCommittedStroke(2);
    addTearDown(document.dispose);
    final draft = DraftStroke()..begin(const Offset(40, 40));
    addTearDown(draft.dispose);

    final canvas = RecordingCanvas();
    DraftPainter(draft: draft, document: document, ink: ink, width: 4)
        .paint(canvas, const Size(400, 400));

    expect(canvas.deviceStrokeWidths, [4.0]);
  });
}

void pathColorTests() {
  const blue = Color(0xFF5B8FD6);

  test('a committed stroke paints in the colour its own key names', () {
    final document = documentWithCommittedStroke(2);
    addTearDown(document.dispose);
    final canvas = RecordingCanvas();
    StrokePainter(document: document, ink: ink, inkColors: const {'ink': blue})
        .paint(canvas, const Size(400, 400));
    expect(canvas.pathColors.map((c) => c.toARGB32()), [blue.toARGB32()]);
  });

  test('a key the painter does not know falls back to the default ink', () {
    final document = documentWithCommittedStroke(2);
    addTearDown(document.dispose);
    final canvas = RecordingCanvas();
    StrokePainter(
        document: document,
        ink: ink,
        inkColors: const {'other': blue}).paint(canvas, const Size(400, 400));
    expect(canvas.pathColors.map((c) => c.toARGB32()), [ink.toARGB32()]);
  });
}
