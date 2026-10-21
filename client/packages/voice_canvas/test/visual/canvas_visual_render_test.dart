// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A visual sign-off render of the canvas's own paint layers: real pixels,
/// not a description of the code that produces them.
///
/// Nothing on this canvas has ever been looked at rendered before this file:
/// every painter here is exercised only by tests that assert on recorded
/// draw calls (`canvas_painters_test.dart`), never on what actually lands on
/// screen. Run with `SLIMM_CANVAS_VISUAL=1 flutter test
/// test/visual/canvas_visual_render.dart` to write PNGs under
/// `build/canvas-visual/`; without the flag this still runs (and still
/// fails on a real painter exception) but writes nothing, so it stays part
/// of the ordinary suite.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_cursors.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_stroke_drafts.dart';

import 'visual_render_support.dart';
import 'visual_scenes.dart';
import 'visual_tokens.dart';

void main() {
  setUpAll(loadVisualFonts);

  for (final theme in VisualTheme.all) {
    test('kitchen sink at zoom 1, ${theme.name}', () async {
      final document = buildKitchenSink();
      addTearDown(document.dispose);
      await renderVisualScene(
        'kitchen_sink_${theme.name}',
        900,
        600,
        (canvas) =>
            paintCanvasComposite(canvas, document, theme, const Size(900, 600)),
      );
    });

    for (final kind in [
      CanvasObjectKind.note,
      CanvasObjectKind.shape,
      CanvasObjectKind.image
    ]) {
      test('elevation shadow, ${kind.name}, ${theme.name}', () async {
        final document = buildElevationPair(kind);
        addTearDown(document.dispose);
        await renderVisualScene(
          'elevation_${kind.name}_${theme.name}',
          500,
          260,
          (canvas) => paintCanvasComposite(
              canvas, document, theme, const Size(500, 260)),
        );
      });
    }

    test('live in-flight ink beside committed ink, ${theme.name}', () async {
      final document = CanvasDocument()..setViewport(const Size(700, 260));
      document.applyPlaced(
        const CanvasStrokeInput(
          id: 'committed',
          seq: 1,
          zIndex: 1,
          x: 40,
          y: 40,
          w: 300,
          h: 1,
          points: [0, 0, 300, 0],
          width: 5,
          colorKey: 'ink',
        ),
      );
      document.refresh();
      addTearDown(document.dispose);
      final drafts = RemoteStrokeDrafts()
        ..appendOrCreate(
          objectId: 'remote-draft',
          authorId: 'someone-else',
          points: const [40, 140, 200, 150, 340, 130],
          colorIndex: 0,
        );
      addTearDown(drafts.dispose);
      await renderVisualScene(
        'live_ink_${theme.name}',
        700,
        260,
        (canvas) => paintCanvasComposite(
          canvas,
          document,
          theme,
          const Size(700, 260),
          drafts: drafts,
        ),
      );
    });

    test('remote cursors, ${theme.name}', () async {
      final document = CanvasDocument()..setViewport(const Size(700, 220));
      addTearDown(document.dispose);
      final cursors = CanvasCursors();
      addTearDown(cursors.dispose);
      const labels = ['Priya', 'Nick', 'Avery', 'Sam', 'Jordan', 'Robin'];
      for (var i = 0; i < labels.length; i++) {
        cursors.upsert(
          id: 'user-$i',
          x: 40.0 + i * 110,
          y: 40.0 + (i.isEven ? 0 : 90),
          label: labels[i],
          colorIndex: i,
        );
      }
      await renderVisualScene(
        'cursors_${theme.name}',
        700,
        220,
        (canvas) => paintCanvasComposite(
          canvas,
          document,
          theme,
          const Size(700, 220),
          cursors: cursors,
        ),
      );
    });
  }

  for (final zoom in [0.25, 1.0, 4.0]) {
    test('shape and ink proportions at zoom $zoom', () async {
      final document = buildZoomStressScene();
      addTearDown(document.dispose);
      const margin = 40.0;
      const worldW = 880.0;
      const worldH = 280.0;
      final width = (worldW * zoom).round();
      final height = (worldH * zoom).round();
      document.setViewport(Size(width.toDouble(), height.toDouble()));
      document.setCamera(Camera(x: -margin, y: -margin, zoom: zoom));
      await renderVisualScene(
        'zoom_stress_${zoom}x',
        width,
        height,
        (canvas) => paintCanvasComposite(
          canvas,
          document,
          VisualTheme.dark,
          Size(width.toDouble(), height.toDouble()),
        ),
      );
    });
  }

  test('selected note with resize handles at three zooms', () async {
    for (final zoom in [0.25, 1.0, 4.0]) {
      final document = CanvasDocument()..setViewport(const Size(400, 300));
      document.applyPlaced(
        const CanvasStrokeInput(
          id: 'sel-note',
          seq: 1,
          zIndex: 1,
          x: 40,
          y: 40,
          w: 220,
          h: 140,
          points: [],
          width: 0,
          colorKey: 'note',
          kind: CanvasObjectKind.note,
          text: 'Selected',
        ),
      );
      document.selectedObjectId.value = 'sel-note';
      document.setCamera(Camera(x: -20, y: -20, zoom: zoom));
      addTearDown(document.dispose);
      await renderVisualScene(
        'selection_handles_${zoom}x',
        400,
        300,
        (canvas) => paintCanvasComposite(
            canvas, document, VisualTheme.dark, const Size(400, 300)),
      );
    }
  });

  test('a note far too long for its box: does it clip mid-line', () async {
    final document = CanvasDocument();
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 'overflow-note',
        seq: 1,
        zIndex: 1,
        x: 20,
        y: 20,
        w: 220,
        h: 140,
        points: [],
        width: 0,
        colorKey: 'note',
        kind: CanvasObjectKind.note,
        text: '$longNoteText $longNoteText',
      ),
    );
    document.setViewport(const Size(260, 180));
    document.refresh();
    addTearDown(document.dispose);
    await renderVisualScene(
      'note_overflow_hard_clip',
      260,
      180,
      (canvas) => paintCanvasComposite(
          canvas, document, VisualTheme.light, const Size(260, 180)),
    );
  });
}
