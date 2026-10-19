// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas's committed-content paint layers: the lattice and the
/// permanently placed ink, images, notes and shapes.
///
/// Each takes its own `repaint` listenable, which is the shape the Phase 5
/// spike's `benchmark/paint_paths.dart` proved: the painter object is
/// constructed once and a camera move repaints without any widget rebuilding.
/// `shouldRepaint` is true only for a replaced instance, which `CanvasSurface`
/// builds only when a colour changes (a theme switch).
///
/// Colours arrive as plain [Color]s from the app layer. This package does not
/// depend on the design system, the same convention every existing painter in
/// the client follows.
///
/// The ephemeral layers - this device's own in-progress stroke, everyone
/// else's in-flight strokes, and everyone's live cursors - live in
/// `canvas_live_painters.dart`, re-exported below so nothing importing this
/// file has to know about the split.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'canvas_document.dart';
import 'canvas_snap.dart' show gridSpacingFor;
import 'note_label_cache.dart';

export 'canvas_live_painters.dart';

/// A note's and a shape's own paint methods, plus the arrowhead's pure
/// geometry: split out once they pushed this file past the 300-line review
/// budget, the same `part of` shape `canvas_document_selection.dart` and
/// `canvas_ops_controller_reorder.dart` already use for a class that grew a
/// second cohesive group of methods rather than a second class.
part 'canvas_painters_shapes.dart';

/// The background lattice, at a spacing quantised to the zoom so the mesh
/// keeps roughly the same density on screen at any scale.
class GridPainter extends CustomPainter {
  GridPainter({required this.document, required this.line, this.letterbox})
      : super(repaint: document);

  final CanvasDocument document;
  final Color line;

  /// The tint outside the shared board; null leaves it unframed.
  final Color? letterbox;

  @override
  void paint(Canvas canvas, Size size) {
    final board = document.board;
    if (board == null || letterbox == null) return _paintLattice(canvas, size);
    final camera = document.camera;
    final frame = Rect.fromLTWH(
      (board.left - camera.x) * camera.zoom,
      (board.top - camera.y) * camera.zoom,
      board.width * camera.zoom,
      board.height * camera.zoom,
    );
    canvas
      ..save()
      ..clipRect(frame);
    _paintLattice(canvas, size);
    canvas.restore();
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(frame),
      Paint()..color = letterbox!,
    );
    canvas.drawRect(
      frame,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _paintLattice(Canvas canvas, Size size) {
    final zoom = document.camera.zoom;
    final spacing = gridSpacingFor(zoom);

    final paint = Paint()
      ..color = line
      ..strokeWidth = 1;
    // Ceil, not floor: a line before the camera would land at a negative offset, outside this painter's box.
    final firstX = (document.camera.x / spacing).ceilToDouble() * spacing;
    final firstY = (document.camera.y / spacing).ceilToDouble() * spacing;
    for (var wx = firstX;
        (wx - document.camera.x) * zoom <= size.width;
        wx += spacing) {
      final sx = (wx - document.camera.x) * zoom;
      canvas.drawLine(Offset(sx, 0), Offset(sx, size.height), paint);
    }
    for (var wy = firstY;
        (wy - document.camera.y) * zoom <= size.height;
        wy += spacing) {
      final sy = (wy - document.camera.y) * zoom;
      canvas.drawLine(Offset(0, sy), Offset(size.width, sy), paint);
    }
  }

  @override
  bool shouldRepaint(GridPainter oldDelegate) => false;
}

/// Styles a note's text: markdown, mentions and emoji as spans over [base].
typedef NoteSpanBuilder = InlineSpan Function(String text, TextStyle base);

/// The committed ink.
class StrokePainter extends CustomPainter {
  StrokePainter({
    required this.document,
    required this.ink,
    this.inkColors = const {},
    this.noteColor,
    this.shapeColor,
    this.textInk = const Color(0xFF1A1A1A),
    this.textFontFamily,
    this.noteSpans,
    this.noteSpansRevision = 0,
    this.placeholderFill = const Color(0xFFB9C0C8),
    this.placeholderIcon = const Color(0xFF6C757E),
    this.elevationShadow = const [],
  }) : super(repaint: Listenable.merge([document, document.elevatedObjectId]));

  final CanvasDocument document;

  /// A pen stroke's own colour, and the fallback for [noteColor] and
  /// [shapeColor] when the caller has no opinion about either - the same
  /// "cheap to omit" shape [CanvasSurface.cursorColors] already uses.
  final Color ink;

  /// Pen colours by the wire `color` key; a stroke whose key is absent here
  /// (an older or newer client's) paints in [ink] rather than vanishing.
  final Map<String, Color> inkColors;
  final Color? noteColor;
  final Color? shapeColor;

  /// A note's own text colour. Deliberately not derived from [noteColor]:
  /// the note's fill is a translucent tint of its own accent hue, and text
  /// legible against every theme needs a colour of its own rather than
  /// riding whatever the accent happens to be.
  final Color textInk;
  final String? textFontFamily;

  /// How a note's text becomes spans; null paints it as plain text.
  final NoteSpanBuilder? noteSpans;

  /// Bumped by the owner when what [noteSpans] reads changes, so cached note
  /// layouts rebuild.
  final int noteSpansRevision;

  /// The muted fill and glyph stroke for an image whose bytes could not be
  /// fetched or decoded. Default to plain neutral greys so a caller with no
  /// opinion (a test, a benchmark) still gets a visible placeholder; the
  /// app layer overrides both with its own design tokens.
  final Color placeholderFill;
  final Color placeholderIcon;

  /// The shadow drawn under whichever image `document.elevatedObjectId`
  /// currently names - a plain `BoxShadow` list rather than a design-system
  /// token, this package's usual "no design-system dependency" convention.
  /// Empty draws no elevation at all, the same "pay nothing for it unwired"
  /// choice `CanvasSurface.selectionOutline` already makes.
  final List<BoxShadow> elevationShadow;

  final NoteLabelCache _noteLabels = NoteLabelCache();

  /// Frees the note-text cache; a [CustomPainter] has no teardown hook of its
  /// own, so the owning surface calls this from its own `dispose`.
  void disposeNoteLabels() => _noteLabels.dispose();

  @visibleForTesting
  int get debugNoteLabelCacheSize => _noteLabels.size;

  @override
  void paint(Canvas canvas, Size size) {
    final camera = document.camera;
    final elevated = document.elevatedObjectId.value;
    final noteIds = <String>{};
    final paint = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    for (final slot in document.paintOrder) {
      final stroke = document.strokeAt(slot);
      final isElevated = stroke.id == elevated;
      switch (stroke.kind) {
        case CanvasObjectKind.image:
          _paintImage(canvas, stroke, camera, elevated: isElevated);
          continue;
        case CanvasObjectKind.note:
          noteIds.add(stroke.id);
          _paintNote(
            canvas,
            stroke,
            camera,
            noteColor ?? ink,
            elevated: isElevated,
          );
          continue;
        case CanvasObjectKind.shape:
          _paintShape(
            canvas,
            stroke,
            camera,
            shapeColor ?? ink,
            elevated: isElevated,
          );
          continue;
        case CanvasObjectKind.stroke:
          break;
      }
      canvas.save();
      // Recentering, exactly: a screen-sized translate in Dart doubles keeps Skia's float32 rasteriser away from world coordinates.
      canvas.translate(
        (stroke.x - camera.x) * camera.zoom,
        (stroke.y - camera.y) * camera.zoom,
      );
      canvas.scale(camera.zoom);
      paint
        ..color = inkColors[stroke.colorKey] ?? ink
        ..strokeWidth = stroke.width;
      canvas.drawPath(stroke.path, paint);
      canvas.restore();
    }
    // Reconcile every frame so a note culled or removed since the last paint drops its cached text.
    _noteLabels.retain(noteIds);
  }

  /// A live bitmap paints normally; a load that failed for good draws the
  /// placeholder, never silence, so a missing image reads as a stated fact
  /// rather than a blank the eye has to guess at. Anything still in flight
  /// (the ordinary case just after a fetch or catch-up) draws nothing yet,
  /// and the object reappears the moment [CanvasDocument.setImageBitmap]
  /// lands and repaints.
  void _paintImage(
    Canvas canvas,
    CanvasStroke stroke,
    Camera camera, {
    required bool elevated,
  }) {
    final dst = Rect.fromLTWH(
      (stroke.x - camera.x) * camera.zoom,
      (stroke.y - camera.y) * camera.zoom,
      stroke.w * camera.zoom,
      stroke.h * camera.zoom,
    );
    if (elevated) _paintElevation(canvas, dst);
    final bitmap = stroke.image;
    if (bitmap == null) {
      if (stroke.imageLoadFailed) _paintImagePlaceholder(canvas, dst);
      return;
    }
    final src = Rect.fromLTWH(
      0,
      0,
      bitmap.width.toDouble(),
      bitmap.height.toDouble(),
    );
    canvas.drawImageRect(bitmap, src, dst, _imagePaint);
  }

  /// Shared across images and repaints; nothing about it varies per image.
  static final Paint _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium;

  /// Drawn first, since a shadow always sits behind whatever casts it -
  /// before the bitmap or the placeholder, both of which paint over it.
  /// Applies regardless of which of those two the image is currently
  /// showing, so a drag started before a decode lands still reads as lifted.
  void _paintElevation(Canvas canvas, Rect box) {
    for (final shadow in elevationShadow) {
      canvas.drawRect(
        box.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }
  }

  /// A muted box plus a broken-picture glyph (a small square with a
  /// diagonal tear), never colour alone: the same "never one channel alone"
  /// rule this project's own presence indicators already follow, here shape
  /// against a muted fill rather than colour against a status dot.
  void _paintImagePlaceholder(Canvas canvas, Rect box) {
    final fill = Paint()..color = placeholderFill;
    final line = Paint()
      ..color = placeholderIcon
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rounded = RRect.fromRectAndRadius(box, const Radius.circular(6));
    canvas.drawRRect(rounded, fill);
    canvas.drawRRect(rounded.deflate(0.75), line);

    final glyphSize = math.min(box.width, box.height) * 0.32;
    if (glyphSize < 6) return;
    final glyph = Rect.fromCenter(
      center: box.center,
      width: glyphSize,
      height: glyphSize,
    );
    canvas.drawRect(glyph, line);
    canvas.drawLine(glyph.topLeft, glyph.bottomRight, line);
  }

  @override
  // A new instance only ever comes from a colour change (CanvasSurface.didUpdateWidget).
  bool shouldRepaint(StrokePainter oldDelegate) =>
      !identical(oldDelegate, this);
}
