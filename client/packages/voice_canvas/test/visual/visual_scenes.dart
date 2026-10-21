// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Scene builders and the layer composite for `canvas_visual_render_test.dart`,
/// split out once that file's own test bodies pushed it past the review
/// budget - the same `part of`-free sibling-file split this package's own
/// production code already uses for an unrelated pair of concerns.
library;

import 'package:flutter/rendering.dart';
import 'package:slimm_voice_canvas/src/canvas_cursors.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';
import 'package:slimm_voice_canvas/src/canvas_stroke_drafts.dart';
import 'package:slimm_voice_canvas/src/selection_painter.dart';

import 'visual_render_support.dart';
import 'visual_tokens.dart';

const longNoteText =
    'Standup notes: ship the canvas review, check every theme including '
    'true black, confirm notes and shapes read as this product rather than '
    'a generic drawing tool, and see whether this much text still fits in '
    'a note sized for three lines or whether it just runs off the bottom '
    'with nothing telling you it did.';

/// Every ink layer the real pane paints, in the same order - the grid via
/// `CanvasGridLayer`, the rest via `CanvasSurface`'s own stack - over the
/// surface colour `CanvasPaneBody`'s own `Container(color: tokens
/// .surfaceBase, ...)` wraps everything in.
void paintCanvasComposite(
  Canvas canvas,
  CanvasDocument document,
  VisualTheme theme,
  Size size, {
  RemoteStrokeDrafts? drafts,
  CanvasCursors? cursors,
}) {
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.width, size.height),
    Paint()..color = theme.surfaceBase,
  );
  GridPainter(document: document, line: theme.borderSubtle).paint(canvas, size);
  StrokePainter(
    document: document,
    ink: VisualCanvasColors.annotation,
    noteColor: VisualCanvasColors.note,
    shapeColor: VisualCanvasColors.shape,
    textInk: theme.textPrimary,
    textFontFamily: visualSansFamily,
    placeholderFill: theme.stripe,
    placeholderIcon: theme.textDisabled,
    elevationShadow: visualFloatShadow,
  ).paint(canvas, size);
  if (drafts != null) {
    RemoteDraftPainter(
      drafts: drafts,
      document: document,
      colors: VisualCanvasColors.cursors,
    ).paint(canvas, size);
  }
  if (document.selectedObjectId.value != null) {
    SelectionPainter(
      document: document,
      outline: theme.accentFill,
      handleFill: theme.surfaceRaised,
      handleBorder: theme.accentFill,
    ).paint(canvas, size);
  }
  if (cursors != null) {
    CursorPainter(
      cursors: cursors,
      document: document,
      colors: VisualCanvasColors.cursors,
      labelFontFamily: visualSansFamily,
    ).paint(canvas, size);
  }
}

/// An ink stroke, world-scaled the way a pen mark actually paints.
CanvasStrokeInput _ink(
  String id,
  int seq,
  double x,
  double y,
  double w,
  double h,
  List<double> points,
  double width,
) =>
    CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: seq,
      x: x,
      y: y,
      w: w,
      h: h,
      points: points,
      width: width,
      colorKey: 'ink',
    );

/// A shape object of [shapeKind], screen-space stroke width regardless of
/// zoom - see the render's own findings for what that means beside [_ink].
CanvasStrokeInput _shape(
  String id,
  int seq,
  double x,
  double y,
  double w,
  double h,
  CanvasShapeKind shapeKind,
) =>
    CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: seq,
      x: x,
      y: y,
      w: w,
      h: h,
      points: const [],
      width: 0,
      colorKey: 'shape',
      kind: CanvasObjectKind.shape,
      shapeKind: shapeKind,
    );

CanvasStrokeInput _note(
  String id,
  int seq,
  double x,
  double y,
  double w,
  double h,
  String text,
) =>
    CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: seq,
      x: x,
      y: y,
      w: w,
      h: h,
      points: const [],
      width: 0,
      colorKey: 'note',
      kind: CanvasObjectKind.note,
      text: text,
    );

/// A pen stroke at three widths, a short note, a note long enough to test
/// overflow, all four shape kinds, and a failed image placeholder - laid out
/// so a single 900x600 viewport at zoom 1 shows every one of them at once.
CanvasDocument buildKitchenSink() {
  final document = CanvasDocument();
  document
      .applyPlaced(_ink('thin', 1, 40, 40, 820, 1, const [0, 0, 820, 0], 1));
  document.applyPlaced(
    _ink(
        'wave',
        2,
        40,
        70,
        820,
        60,
        const [
          0, 40, //
          100, 0, 200, 60, 300, 0, 400, 60, //
          500, 0, 600, 60, 700, 0, 820, 40,
        ],
        4),
  );
  document.applyPlaced(
    _ink('thick', 3, 60, 150, 240, 20, const [0, 0, 240, 20], 14),
  );
  document.applyPlaced(
    _note('note-short', 4, 40, 200, 220, 140,
        'Meeting notes\nBring the mockups.'),
  );
  document.applyPlaced(
    _note('note-long', 5, 280, 200, 220, 140, longNoteText),
  );
  const shapeKinds = [
    CanvasShapeKind.rectangle,
    CanvasShapeKind.ellipse,
    CanvasShapeKind.line,
    CanvasShapeKind.arrow,
  ];
  for (var i = 0; i < shapeKinds.length; i++) {
    document.applyPlaced(
      _shape(
        'shape-${shapeKinds[i].name}',
        6 + i,
        40.0 + i * 180,
        380,
        160,
        100,
        shapeKinds[i],
      ),
    );
  }
  document.applyPlaced(
    const CanvasStrokeInput(
      id: 'image-missing',
      seq: 10,
      zIndex: 10,
      x: 760,
      y: 380,
      w: 100,
      h: 100,
      points: [],
      width: 0,
      colorKey: '',
      kind: CanvasObjectKind.image,
      attachmentId: 'sha-missing',
    ),
  );
  document.markImageLoadFailed('image-missing');
  document.setViewport(const Size(900, 600));
  document.refresh();
  return document;
}

/// One idle and one elevated object of [kind], side by side, so a shadow's
/// size and softness can be compared against a plain object right next to it
/// rather than only against its own doc comment.
CanvasDocument buildElevationPair(CanvasObjectKind kind) {
  final document = CanvasDocument();
  final (colorKey, shapeKind) = switch (kind) {
    CanvasObjectKind.note => ('note', null),
    CanvasObjectKind.shape => ('shape', CanvasShapeKind.rectangle),
    _ => ('', null),
  };
  for (final (id, x) in [('idle', 40.0), ('elevated', 280.0)]) {
    document.applyPlaced(
      CanvasStrokeInput(
        id: id,
        seq: 1,
        zIndex: 1,
        x: x,
        y: 60,
        w: 180,
        h: 140,
        points: const [],
        width: 0,
        colorKey: colorKey,
        kind: kind,
        text: kind == CanvasObjectKind.note ? 'Idle vs elevated' : null,
        shapeKind: shapeKind,
        attachmentId: kind == CanvasObjectKind.image ? 'sha-x' : null,
      ),
    );
  }
  if (kind == CanvasObjectKind.image) {
    document.markImageLoadFailed('idle');
    document.markImageLoadFailed('elevated');
  }
  document.elevatedObjectId.value = 'elevated';
  document.setViewport(const Size(500, 260));
  document.refresh();
  return document;
}

/// A diagonal ink stroke, a rectangle, an arrow and a flat line, spread out
/// so the same world region can be rendered at several zooms and compared:
/// ink scales in world space, but a shape's outline is fixed screen-space
/// width - see the render's own findings for what that means visually.
CanvasDocument buildZoomStressScene() {
  final document = CanvasDocument();
  document
      .applyPlaced(_ink('diag', 1, 0, 0, 200, 200, const [0, 0, 200, 200], 4));
  document.applyPlaced(
    _shape('rect', 2, 250, 0, 150, 150, CanvasShapeKind.rectangle),
  );
  document.applyPlaced(
    _shape('arrow', 3, 450, 25, 150, 100, CanvasShapeKind.arrow),
  );
  document.applyPlaced(
    _shape('flat-line', 4, 650, 90, 150, 20, CanvasShapeKind.line),
  );
  document.setViewport(const Size(880, 280));
  document.refresh();
  return document;
}
