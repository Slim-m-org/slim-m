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
    const pad = 8.0;
    if (text == null ||
        text.isEmpty ||
        box.width <= pad * 2 ||
        box.height <= pad * 2) {
      return;
    }
    const lineHeightMultiple = 1.3;
    final fontSize = 12 * camera.zoom;
    // Keyed on all the layout depends on: a pan holds these steady and hits, a zoom or resize changes one and rebuilds.
    final painter = _noteLabels.painterFor(
      stroke.id,
      (text, camera.zoom, stroke.w, stroke.h),
      () => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: textFontFamily,
            fontSize: fontSize,
            color: textInk,
            height: lineHeightMultiple,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: noteMaxLines(
          box.height,
          fontSize * lineHeightMultiple,
          pad: pad,
        ),
        ellipsis: '…',
      )..layout(maxWidth: box.width - pad * 2, minWidth: 0),
    );
    canvas.save();
    // A clip at exactly `pad`, matching the text's own offset below.
    canvas.clipRect(box.deflate(pad));
    painter.paint(canvas, box.topLeft + const Offset(pad, pad));
    canvas.restore();
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
    final paint = _shapeStroke..color = color;
    switch (stroke.shapeKind) {
      case CanvasShapeKind.ellipse:
        canvas.drawOval(local, paint);
      case CanvasShapeKind.line:
        canvas.drawLine(local.topLeft, local.bottomRight, paint);
      case CanvasShapeKind.arrow:
        canvas.drawLine(local.topLeft, local.bottomRight, paint);
        _paintArrowhead(canvas, local.topLeft, local.bottomRight, paint);
      case CanvasShapeKind.rectangle:
      case null:
        canvas.drawRect(local, paint);
    }
    canvas.restore();
  }

  void _paintArrowhead(Canvas canvas, Offset from, Offset to, Paint paint) {
    final (left, right) = arrowheadWings(from, to);
    canvas.drawLine(to, left, paint);
    canvas.drawLine(to, right, paint);
  }
}

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
