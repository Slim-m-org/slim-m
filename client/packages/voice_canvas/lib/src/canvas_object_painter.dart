// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import 'canvas_ink.dart';
import 'ellipse_path.dart';
import 'canvas_document.dart';
import 'canvas_note_layout.dart';
import 'canvas_text_box.dart';
import 'note_label_cache.dart';

/// The thinnest a stroke is ever painted, in screen pixels, so ink drawn while
/// zoomed in stays visible to someone viewing the whole board.
const double minInkScreenPx = 1.5;

/// Paints notes, text boxes and shapes for a [StrokePainter], which owns the
/// colours and fonts and hands them in; the paints below are static so a
/// repaint per frame allocates none.
class ObjectPainter {
  ObjectPainter({
    required this.ink,
    required this.inkColors,
    required this.textInk,
    required this.textFontFamily,
    required this.noteSpans,
    required this.noteSpansRevision,
    required this.elevationShadow,
    this.palette = const NotePalette(),
  });

  final Color ink;
  final Map<String, Color> inkColors;
  final Color textInk;
  final String? textFontFamily;
  final NoteSpanBuilder? noteSpans;
  final int noteSpansRevision;
  final List<BoxShadow> elevationShadow;

  /// The colours a note's fill and text resolve through.
  final NotePalette palette;

  final NoteLabelCache noteLabels = NoteLabelCache();

  /// Reused across objects and repaints, recoloured per object: `paint()`
  /// visits every note and shape on each repaint, including every frame of a
  /// pan or zoom, so a fresh Paint per object was a steady per-frame churn
  /// the ink branch in `paint()` already avoids by hoisting its own.
  static final Paint _noteFill = Paint();
  static final Paint _noteStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  static final Paint _checkTick = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  static final Paint _shapeStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..isAntiAlias = true;

  /// A tinted box with a text body, painted in screen space the same way
  /// `_paintImage` already projects its own box - simpler than the
  /// world-scale `save`/`translate`/`scale` the ink branch uses, and correct
  /// here because the text layout width is computed straight from the
  /// already-projected screen box rather than from a world-space one. The
  /// clip is deflated by exactly `pad` on every side, matching the text's
  /// own `pad`-offset origin, so a bottom margin reads the same as the top
  /// rather than the text running up to a boundary tighter than its own
  /// [noteMaxLines]-bounded layout was ever going to reach.
  void paintNote(
    Canvas canvas,
    CanvasStroke stroke,
    Camera camera,
    Color color, {
    required bool elevated,
    bool editing = false,
  }) {
    final box = Rect.fromLTWH(
      (stroke.x - camera.x) * camera.zoom,
      (stroke.y - camera.y) * camera.zoom,
      stroke.w * camera.zoom,
      stroke.h * camera.zoom,
    );
    if (elevated) paintElevation(canvas, box);
    final style = stroke.noteStyle;
    final fill = palette.fillOf(style, color);
    final opacity = style.fillOpacity ?? canvasNoteTintedOpacity;
    final rounded = RRect.fromRectAndRadius(box, const Radius.circular(6));
    if (opacity > 0) {
      canvas.drawRRect(
          rounded, _noteFill..color = fill.withValues(alpha: opacity));
    }
    canvas.drawRRect(rounded.deflate(0.75), _noteStroke..color = fill);
    final text = stroke.text;
    final fontSize = noteTextSizeOf(noteFontSizeFor(stroke.w, stroke.h), style);
    if (editing ||
        text == null ||
        text.isEmpty ||
        stroke.w <= noteWorldPad * 2 ||
        stroke.h <= noteWorldPad * 2 ||
        fontSize * camera.zoom < minNoteTextScreenPx) {
      return;
    }
    final ink = palette.inkOf(style, color);
    // Laid out in world units: the wrap and the line budget are the same on every viewer's screen, and a zoom only scales the result.
    final painter = noteLabels.painterFor(
      stroke.id,
      (text, stroke.w, stroke.h, Object.hash(noteSpansRevision, ink), fontSize),
      () => layoutNoteText(
        _noteSpan(text, fontSize, noteLineHeight, ink),
        fontSize: fontSize,
        width: stroke.w - noteWorldPad * 2,
        maxLines: noteMaxLines(
          stroke.h,
          fontSize * noteLineHeight,
          pad: noteWorldPad,
        ),
      ),
    );
    canvas.save();
    canvas.translate(box.left, box.top);
    canvas.scale(camera.zoom);
    canvas.clipRect(
      Rect.fromLTWH(
        noteWorldPad,
        noteWorldPad,
        stroke.w - noteWorldPad * 2,
        stroke.h - noteWorldPad * 2,
      ),
    );
    painter.paint(canvas, const Offset(noteWorldPad, noteWorldPad));
    _paintChecks(canvas, painter, ink, palette.behind(style, color));
    canvas.restore();
  }

  void _paintChecks(
      Canvas canvas, TextPainter painter, Color ink, Color behind) {
    for (final check in noteChecksOf(painter)) {
      final rect = check.rect
          .shift(const Offset(noteWorldPad, noteWorldPad))
          .deflate(check.rect.width * 0.12);
      final rounded =
          RRect.fromRectAndRadius(rect, Radius.circular(rect.width * 0.2));
      if (check.checked) {
        canvas.drawRRect(rounded, _noteFill..color = ink);
        canvas.drawPath(
          Path()
            ..moveTo(
                rect.left + rect.width * 0.25, rect.top + rect.height * 0.52)
            ..lineTo(
                rect.left + rect.width * 0.43, rect.top + rect.height * 0.7)
            ..lineTo(
                rect.left + rect.width * 0.75, rect.top + rect.height * 0.32),
          _checkTick
            ..color = behind
            ..strokeWidth = rect.width * 0.14,
        );
      } else {
        canvas.drawRRect(
            rounded,
            _noteStroke
              ..color = ink
              ..strokeWidth = rect.width * 0.1);
        _noteStroke.strokeWidth = 1.5;
      }
    }
  }

  /// A text box: glyphs only, in the box's own colour, wrapped at its width and clipped to its height.
  void paintText(
    Canvas canvas,
    CanvasStroke stroke,
    Camera camera, {
    bool editing = false,
  }) {
    final text = stroke.text;
    final fontSize = canvasTextFontSizes[stroke.textSize] ??
        canvasTextFontSizes[canvasDefaultTextSize]!;
    if (editing ||
        text == null ||
        text.isEmpty ||
        stroke.w <= canvasTextPad * 2 ||
        fontSize * camera.zoom < minNoteTextScreenPx) {
      return;
    }
    // A text box's layout does not depend on its height, so the key's height slot is 0 and its colour rides in the revision slot.
    final painter = noteLabels.painterFor(
      stroke.id,
      (text, stroke.w, 0, stroke.colorKey.hashCode, fontSize),
      () => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: textFontFamily,
            fontSize: fontSize,
            color: stroke.colorKey == canvasDefaultTextColor
                ? textInk
                : resolveCanvasInk(inkColors, stroke.colorKey, ink),
            height: canvasTextLineHeight,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: stroke.w - canvasTextPad * 2, minWidth: 0),
    );
    canvas.save();
    canvas.translate(
      (stroke.x - camera.x) * camera.zoom,
      (stroke.y - camera.y) * camera.zoom,
    );
    canvas.scale(camera.zoom);
    canvas.clipRect(Rect.fromLTWH(0, 0, stroke.w, stroke.h));
    painter.paint(canvas, const Offset(canvasTextPad, canvasTextPad));
    canvas.restore();
  }

  InlineSpan _noteSpan(String text, double fontSize, double height, Color ink) {
    final base = TextStyle(
      fontFamily: textFontFamily,
      fontSize: fontSize,
      color: ink,
      height: height,
    );
    return noteSpans?.call(text, base) ?? TextSpan(text: text, style: base);
  }

  /// A shape's own box, drawn as whichever of [CanvasShapeKind] it names. A
  /// line or an arrow is always the box's own diagonal - see
  /// [CanvasShapeKind]'s own doc for why that is what makes a resize the
  /// whole reshape mechanism, with nothing else to keep in step.
  ///
  /// A shape somebody drew is content by the same test a pen stroke already
  /// is, so it is drawn under the identical `translate`/`scale` world-space
  /// transform the ink branch uses, in [stroke]'s own local (world-unit)
  /// coordinates - not the screen-space projected box a chrome element like
  /// the selection outline uses. That is what makes the outline and the
  /// arrowhead both scale with zoom the way a pen stroke's width already
  /// does, rather than staying a fixed screen-space thickness regardless of
  /// how large the shape has been zoomed.
  void paintShape(
    Canvas canvas,
    CanvasStroke stroke,
    Camera camera,
    Color color, {
    required bool elevated,
  }) {
    if (elevated) {
      paintElevation(
        canvas,
        Rect.fromLTWH(
          (stroke.x - camera.x) * camera.zoom,
          (stroke.y - camera.y) * camera.zoom,
          stroke.w * camera.zoom,
          stroke.h * camera.zoom,
        ),
      );
    }
    canvas.save();
    canvas.translate(
      (stroke.x - camera.x) * camera.zoom,
      (stroke.y - camera.y) * camera.zoom,
    );
    canvas.scale(camera.zoom);
    final local = Rect.fromLTWH(0, 0, stroke.w, stroke.h);
    final (tail, head) = shapeSegment(
      stroke.w,
      stroke.h,
      flipX: stroke.flipX,
      flipY: stroke.flipY,
    );
    final paint = _shapeStroke
      ..color = color
      ..strokeWidth = math.max(shapeOutlineWorld, minInkScreenPx / camera.zoom);
    switch (stroke.shapeKind) {
      case CanvasShapeKind.ellipse:
        drawEllipse(canvas, local, paint);
      case CanvasShapeKind.line:
        canvas.drawLine(tail, head, paint);
      case CanvasShapeKind.arrow:
        canvas.drawLine(tail, head, paint);
        _paintArrowhead(
          canvas,
          tail,
          head,
          paint,
          math.max(arrowheadLength, minArrowheadScreenPx / camera.zoom),
        );
      case CanvasShapeKind.rectangle:
      case null:
        canvas.drawRect(local, paint);
    }
    canvas.restore();
  }

  void _paintArrowhead(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint,
    double headLength,
  ) {
    final (left, right) = arrowheadWings(from, to, headLength: headLength);
    canvas.drawLine(to, left, paint);
    canvas.drawLine(to, right, paint);
  }

  /// Drawn first, since a shadow always sits behind whatever casts it.
  void paintElevation(Canvas canvas, Rect box) {
    for (final shadow in elevationShadow) {
      canvas.drawRect(
        box.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }
  }
}

/// The box a note is placed in by default, and the text size that box carries.
const double noteReferenceWidth = 330;
const double noteReferenceHeight = 210;
const double noteReferenceFontSize = 18;

/// A note's text scales with its box, by whichever side limits it, so a resize keeps the text readable.
double noteFontSizeFor(double w, double h) => math.min(
      noteFontSizeForWidth(w),
      h * noteReferenceFontSize / noteReferenceHeight,
    );

/// The largest text size a note [w] wide can show, which a layout that must always fit plans for.
double noteFontSizeForWidth(double w) =>
    w * noteReferenceFontSize / noteReferenceWidth;

/// Text smaller than this on screen is a smudge, so it is not laid out or drawn.
const double minNoteTextScreenPx = 1.5;

/// A shape's outline width in world units, and the least it shows on screen.
const double shapeOutlineWorld = 2;

/// The least an arrowhead wing reaches on screen.
const double minArrowheadScreenPx = 9;

/// How far back each arrowhead wing reaches, in world units for a committed
/// arrow and scaled by zoom for the live preview.
const double arrowheadLength = 10;

/// The two short segments an arrowhead draws back from [to], pure geometry
/// so it can be tested without a canvas: a `from`-to-`to` line with nothing
/// at its far end does not read as an arrow, and this is the one thing
/// [CanvasShapeKind.arrow] adds over [CanvasShapeKind.line].
(Offset, Offset) arrowheadWings(
  Offset from,
  Offset to, {
  double headLength = arrowheadLength,
  double headAngle = 0.5,
}) {
  final direction = to - from;
  if (direction.distance == 0) return (to, to);
  final angle = math.atan2(direction.dy, direction.dx);
  final left = to -
      Offset(math.cos(angle - headAngle), math.sin(angle - headAngle)) *
          headLength;
  final right = to -
      Offset(math.cos(angle + headAngle), math.sin(angle + headAngle)) *
          headLength;
  return (left, right);
}

/// How many lines of text a note's own box can show, given [pad] on every
/// side and a [lineHeight] in the same pixel space as [boxHeight].
///
/// Pure geometry, no [TextPainter] involved, so it is unit-testable with no
/// canvas at all. This replaced a fixed `maxLines: 200` that made a note's
/// own `ellipsis` effectively dead code: a note-sized box was never going to
/// hold 200 wrapped lines, so text past what actually fit was silently
/// hard-clipped by the paint clip rather than truncated with an ellipsis a
/// reader could see. Tying this to the box is what makes Flutter's own
/// truncation fire instead.
int noteMaxLines(double boxHeight, double lineHeight, {double pad = 8}) {
  final usable = boxHeight - pad * 2;
  if (usable <= 0) return 0;
  return math.max(1, (usable / lineHeight).floor());
}
