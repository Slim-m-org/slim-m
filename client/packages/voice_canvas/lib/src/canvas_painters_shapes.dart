// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_painters.dart';

/// [StrokePainter]'s note and shape paint methods. An extension in a `part
/// of` file, not a second class, since both still need [StrokePainter]'s own
/// private fields (`textInk`, `textFontFamily`) and are called from its
/// `paint` method's own switch.
extension _StrokePainterShapes on StrokePainter {
  /// Reused across objects and repaints, recoloured per object: `paint()`
  /// visits every note and shape on each repaint, including every frame of a
  /// pan or zoom, so a fresh Paint per object was a steady per-frame churn
  /// the ink branch in `paint()` already avoids by hoisting its own.
  static final Paint _noteFill = Paint();
  static final Paint _noteStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
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
  void _paintNote(
    Canvas canvas,
    CanvasStroke stroke,
    Camera camera,
    Color color, {
    required bool elevated,
  }) {
    final box = Rect.fromLTWH(
      (stroke.x - camera.x) * camera.zoom,
      (stroke.y - camera.y) * camera.zoom,
      stroke.w * camera.zoom,
      stroke.h * camera.zoom,
    );
    if (elevated) _paintElevation(canvas, box);
    final rounded = RRect.fromRectAndRadius(box, const Radius.circular(6));
    canvas.drawRRect(
      rounded,
      _noteFill..color = color.withValues(alpha: 0.18),
    );
    canvas.drawRRect(rounded.deflate(0.75), _noteStroke..color = color);
    final text = stroke.text;
    if (text == null ||
        text.isEmpty ||
        stroke.w <= noteWorldPad * 2 ||
        stroke.h <= noteWorldPad * 2 ||
        noteWorldFontSize * camera.zoom < minNoteTextScreenPx) {
      return;
    }
    // Laid out in world units: the wrap and the line budget are the same on every viewer's screen, and a zoom only scales the result.
    final painter = _noteLabels.painterFor(
      stroke.id,
      (text, stroke.w, stroke.h, noteSpansRevision),
      () => TextPainter(
        text: _noteSpan(text, noteWorldFontSize, noteLineHeight),
        textDirection: TextDirection.ltr,
        maxLines: noteMaxLines(
          stroke.h,
          noteWorldFontSize * noteLineHeight,
          pad: noteWorldPad,
        ),
        ellipsis: '…',
      )..layout(maxWidth: stroke.w - noteWorldPad * 2, minWidth: 0),
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
    canvas.restore();
  }

  /// A text box: glyphs only, in the box's own colour, wrapped at its width and clipped to its height.
  void _paintText(
    Canvas canvas,
    CanvasStroke stroke,
    Camera camera,
  ) {
    final text = stroke.text;
    final fontSize = canvasTextFontSizes[stroke.textSize] ??
        canvasTextFontSizes[canvasDefaultTextSize]!;
    if (text == null ||
        text.isEmpty ||
        stroke.w <= canvasTextPad * 2 ||
        fontSize * camera.zoom < minNoteTextScreenPx) {
      return;
    }
    // The key's third and fourth slots carry the font size and the colour: a text box's layout does not depend on its height.
    final painter = _noteLabels.painterFor(
      stroke.id,
      (text, stroke.w, fontSize, stroke.colorKey.hashCode),
      () => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: textFontFamily,
            fontSize: fontSize,
            color: inkColors[stroke.colorKey] ?? ink,
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

  InlineSpan _noteSpan(String text, double fontSize, double height) {
    final base = TextStyle(
      fontFamily: textFontFamily,
      fontSize: fontSize,
      color: textInk,
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
  void _paintShape(
    Canvas canvas,
    CanvasStroke stroke,
    Camera camera,
    Color color, {
    required bool elevated,
  }) {
    if (elevated) {
      _paintElevation(
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
        canvas.drawOval(local, paint);
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
}

/// A note's padding, font size and line height, in world units.
const double noteWorldPad = 8;
const double noteWorldFontSize = 12;
const double noteLineHeight = 1.3;

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
